#!/usr/bin/env python3
"""Send freshly uploaded builds to the external TestFlight group.

Waits for App Store Connect to finish processing each build, sets "What to
Test" from the commit that produced it, adds it to the external group, and
submits it for Beta App Review when Apple wants one.

    BUILD_NUMBER=260806.2 Scripts/submit-beta.py [--group "External Testers"]

Exits non-zero only if something it was asked to do failed. A build that is
still processing after the timeout is reported and skipped rather than
treated as an error, because the upload itself already succeeded.
"""
import argparse, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api

PROCESSING_TIMEOUT = 30 * 60      # Apple usually takes 5-15 minutes
POLL_SECONDS = 30

# A build that has only just finished processing can 404 on one App Store
# Connect node while another has already listed it. tvOS was left out of the
# group exactly that way: found in the listing, VALID when polled, then "no
# resource of type 'builds' with id …" on the very next call.
TRANSIENT = (404, 429, 500, 502, 503, 504)
RETRIES = 4
RETRY_PAUSE = 15


def call(method: str, path: str, body=None):
    """asc_api.call, but patient with App Store Connect's eventual consistency."""
    for attempt in range(RETRIES):
        status, payload = asc_api.call(method, path, body)
        if status < 300 or status not in TRANSIENT or attempt == RETRIES - 1:
            return status, payload
        time.sleep(RETRY_PAUSE)


def release_notes() -> str:
    """The commit message, which is what a tester most wants to read."""
    try:
        text = subprocess.run(["git", "log", "-1", "--pretty=%B"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        text = ""
    if not text:
        text = "No release notes for this build."
    return text[:3900]            # whatsNew caps at 4000 characters


def builds_with_number(number: str):
    """Every platform's build carrying this build number.

    Listing failures are swallowed: the caller polls, so a bad answer costs one
    round rather than the whole submission.
    """
    found = []
    status, payload = call("GET", f"/v1/apps/{asc_api.APP_ID}/preReleaseVersions?limit=200")
    if status >= 300:
        return found
    for version in payload["data"]:
        platform = version["attributes"]["platform"]
        status, builds = call("GET", f"/v1/preReleaseVersions/{version['id']}/builds?limit=200")
        if status >= 300:
            continue
        for build in builds["data"]:
            if build["attributes"].get("version") == number:
                found.append((platform, build["id"]))
    return found


def wait_until_processed(build_id: str) -> str:
    deadline = time.time() + PROCESSING_TIMEOUT
    state = "UNKNOWN"
    while time.time() < deadline:
        status, payload = call("GET", f"/v1/builds/{build_id}")
        if status < 300:
            state = payload["data"]["attributes"].get("processingState", "UNKNOWN")
            if state in ("VALID", "FAILED", "INVALID"):
                return state
        time.sleep(POLL_SECONDS)
    return state


def set_release_notes(build_id: str, notes: str):
    """Returns (status, body); anything >= 300 is a real failure to report."""
    status, payload = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")
    if status >= 300:
        return status, payload
    existing = payload["data"]
    if not existing:
        return call("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": notes},
            "relationships": {"build": asc_api.rel("builds", build_id)}}})
    for localization in existing:
        status, payload = call("PATCH", f"/v1/betaBuildLocalizations/{localization['id']}",
                               {"data": {"type": "betaBuildLocalizations",
                                         "id": localization["id"],
                                         "attributes": {"whatsNew": notes}}})
        if status >= 300:
            return status, payload
    return 200, {}


def group_id(name: str):
    for group in asc_api.get(f"/v1/apps/{asc_api.APP_ID}/betaGroups?limit=50")["data"]:
        if group["attributes"]["name"] == name:
            return group["id"], group["attributes"].get("isInternalGroup", False)
    return None, False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--group", default=os.environ.get("BETA_GROUP", "External Testers"))
    parser.add_argument("--build-number", default=os.environ.get("BUILD_NUMBER"))
    parser.add_argument("--expect", default=os.environ.get("EXPECT_PLATFORMS", ""),
                        help="comma-separated platforms that were uploaded, e.g. IOS,TV_OS")
    args = parser.parse_args()

    if not args.build_number:
        print("submit-beta: BUILD_NUMBER is required", file=sys.stderr)
        return 2

    gid, is_internal = group_id(args.group)
    if gid is None:
        print(f"submit-beta: no beta group named {args.group!r}", file=sys.stderr)
        return 1

    expected = {p.strip().upper() for p in args.expect.split(",") if p.strip()}

    # App Store Connect ingests each upload asynchronously, so a build can be
    # missing from the listing for a minute or two after altool returns. Listing
    # once and submitting whatever happened to be there silently skipped the
    # platform that had not landed yet.
    deadline = time.time() + PROCESSING_TIMEOUT
    builds = builds_with_number(args.build_number)
    while expected and time.time() < deadline:
        missing = expected - {platform for platform, _ in builds}
        if not missing:
            break
        print(f"  waiting for {', '.join(sorted(missing))} to appear in App Store Connect…")
        time.sleep(POLL_SECONDS)
        builds = builds_with_number(args.build_number)

    if not builds:
        print(f"submit-beta: no build {args.build_number} found — nothing to submit")
        return 0

    still_missing = expected - {platform for platform, _ in builds}
    for platform in sorted(still_missing):
        print(f"  ! {platform}: never appeared as build {args.build_number} — "
              f"not submitted. Add it by hand in App Store Connect.")

    notes = release_notes()
    print(f"▸ Submitting build {args.build_number} to {args.group!r}")
    print(f"  release notes: {notes.splitlines()[0][:70]}…")

    failures = 0
    for platform, build_id in builds:
        state = wait_until_processed(build_id)
        if state != "VALID":
            print(f"  ! {platform}: still {state} — skipped, submit it by hand if needed")
            continue

        status, body = set_release_notes(build_id, notes)
        if status >= 300:
            print(f"  ✗ {platform}: could not set release notes: {body}")
            failures += 1
            continue

        status, body = call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
                            {"data": [{"type": "builds", "id": build_id}]})
        if status >= 300 and "already" not in str(body).lower():
            print(f"  ✗ {platform}: could not add to {args.group!r}: {body}")
            failures += 1
            continue

        note = ""
        if not is_internal:
            # External testing needs Beta App Review for each new version.
            review, review_body = call("POST", "/v1/betaAppReviewSubmissions", {
                "data": {"type": "betaAppReviewSubmissions",
                         "relationships": {"build": asc_api.rel("builds", build_id)}}})
            if review < 300:
                note = ", submitted for beta review"
            elif "already" in str(review_body).lower() or review == 409:
                note = ", beta review already in progress or not required"
            else:
                note = f", beta review request returned {review}"

        print(f"  ✓ {platform}: notes set, added to {args.group!r}{note}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
