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
    """Every platform's build carrying this build number."""
    found = []
    for version in asc_api.get(
            f"/v1/apps/{asc_api.APP_ID}/preReleaseVersions?limit=50")["data"]:
        platform = version["attributes"]["platform"]
        for build in asc_api.get(
                f"/v1/preReleaseVersions/{version['id']}/builds?limit=200")["data"]:
            if build["attributes"].get("version") == number:
                found.append((platform, build["id"]))
    return found


def wait_until_processed(build_id: str) -> str:
    deadline = time.time() + PROCESSING_TIMEOUT
    state = "UNKNOWN"
    while time.time() < deadline:
        state = asc_api.get(f"/v1/builds/{build_id}")["data"]["attributes"].get(
            "processingState", "UNKNOWN")
        if state in ("VALID", "FAILED", "INVALID"):
            return state
        time.sleep(POLL_SECONDS)
    return state


def set_release_notes(build_id: str, notes: str) -> None:
    existing = asc_api.get(f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
    if existing:
        for localization in existing:
            asc_api.call("PATCH", f"/v1/betaBuildLocalizations/{localization['id']}",
                         {"data": {"type": "betaBuildLocalizations",
                                   "id": localization["id"],
                                   "attributes": {"whatsNew": notes}}})
    else:
        asc_api.call("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": notes},
            "relationships": {"build": asc_api.rel("builds", build_id)}}})


def group_id(name: str):
    for group in asc_api.get(f"/v1/apps/{asc_api.APP_ID}/betaGroups?limit=50")["data"]:
        if group["attributes"]["name"] == name:
            return group["id"], group["attributes"].get("isInternalGroup", False)
    return None, False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--group", default=os.environ.get("BETA_GROUP", "External Testers"))
    parser.add_argument("--build-number", default=os.environ.get("BUILD_NUMBER"))
    args = parser.parse_args()

    if not args.build_number:
        print("submit-beta: BUILD_NUMBER is required", file=sys.stderr)
        return 2

    gid, is_internal = group_id(args.group)
    if gid is None:
        print(f"submit-beta: no beta group named {args.group!r}", file=sys.stderr)
        return 1

    builds = builds_with_number(args.build_number)
    if not builds:
        print(f"submit-beta: no build {args.build_number} found — nothing to submit")
        return 0

    notes = release_notes()
    print(f"▸ Submitting build {args.build_number} to {args.group!r}")
    print(f"  release notes: {notes.splitlines()[0][:70]}…")

    failures = 0
    for platform, build_id in builds:
        state = wait_until_processed(build_id)
        if state != "VALID":
            print(f"  ! {platform}: still {state} — skipped, submit it by hand if needed")
            continue

        set_release_notes(build_id, notes)

        status, body = asc_api.call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
                                    {"data": [{"type": "builds", "id": build_id}]})
        if status >= 300 and "already" not in str(body).lower():
            print(f"  ✗ {platform}: could not add to {args.group!r}: {body}")
            failures += 1
            continue

        note = ""
        if not is_internal:
            # External testing needs Beta App Review for each new version.
            review, review_body = asc_api.call("POST", "/v1/betaAppReviewSubmissions", {
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
