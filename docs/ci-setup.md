# Build and release setup

Status Board builds on **media** (`192.168.1.10`, Apple silicon, Xcode 26.6)
and uploads to TestFlight with an App Store Connect API key.

Two workflows share that runner:

| Workflow | Fires on | Does |
| --- | --- | --- |
| [`Build and Release`](../.github/workflows/release.yml) | any push to `main`, `v*` tags | tests, builds, signs, uploads to TestFlight |
| [`Deploy website`](../.github/workflows/deploy-website.yml) | pushes to `main` touching `website/` | publishes <https://statusboard.am.guru> — see [docs/website.md](website.md) |

They use separate concurrency groups, so a one-file website change is not stuck
behind a 90-minute build. The runner still takes one job at a time, so when a
commit touches both, they run back to back.

`media` is a LAN address, so GitHub-hosted runners cannot SSH to it. The
workflow therefore runs on a **self-hosted runner installed on media** — that
is the supported way to build on a machine GitHub can't reach.

## The runner on media

Already installed, as a **repository-level** runner in
`~/actions-runner-statusboard`:

| | |
| --- | --- |
| Name | `statusboard-media` |
| Labels | `self-hosted, macOS, X64, media, statusboard` |
| Service | `actions.runner.AM-Guru-StatusBoard.statusboard-media` |

It is repo-level on purpose. media's *other* runner (`macos-build`) belongs to
the org runner group `slaptop-main-release`, whose allow-list is Slaptop and
SybilSight only — StatusBoard cannot schedule jobs on it, and widening that
group would grant this repo access to a privileged machine.

Two things that are easy to get wrong here:

- **X64, not ARM64.** media is Apple silicon, but the native arm64 runner
  package fails to start on it (`Failed to create CoreCLR, HRESULT: 0x8007000C`),
  so it runs the x86_64 package under Rosetta. A workflow asking for an `ARM64`
  label queues forever — which is exactly why nothing ran at first.
- **The service needs Homebrew on its PATH.** `brew` and `xcodegen` live in
  `/opt/homebrew/bin`, which a non-login service shell does not include, so
  `~/actions-runner-statusboard/.env` sets `PATH` explicitly.

Managing it:

```bash
ssh media 'cd ~/actions-runner-statusboard && ./svc.sh status'
```

## Build numbers and beta submission

Build numbers are **`YYMMDD.R`** — `260806.2` is the second build made on
6 August 2026. `Scripts/next-build-number.py` picks `R` by asking App Store
Connect what already exists, so CI, a laptop and a re-run never disagree. It
answers with one more than the highest `YYMMDD.R` uploaded so far, which is
today's date on any normal day — and stays ahead when a machine on a different
timezone has already uploaded under tomorrow's date.

It needs the App Store Connect key, so `ci-release.sh` derives the number only
*after* staging the key, and the script fails rather than guessing if the API
cannot be reached. An earlier version guessed `YYMMDD.1` and every CI run
therefore archived for fifteen minutes before dying at upload on a number that
was already taken.

> `CFBundleVersion` is compared component by component and must increase within
> a marketing version. `260806` is *lower* than the old timestamp style
> (`202608061800`), so adopting this format required moving
> `MARKETING_VERSION` to **1.1**. Changing the format again means bumping the
> marketing version again.

After a successful upload, `Scripts/submit-beta.py`:

1. waits for App Store Connect to finish processing each platform's build,
2. sets **What to Test** from the commit message that produced it,
3. adds the build to the **External Testers** group, and
4. submits it for Beta App Review, which external testing requires per version.

A build still processing when the timeout expires is reported and skipped
rather than failing the run — the upload already succeeded. Override the group
with the `BETA_GROUP` repository variable.

## When the workflow runs

| Event | Test | Build | Upload |
| --- | --- | --- | --- |
| Push to `main` | yes | no | no |
| Push a `v*` tag | yes | yes | yes |
| Manual **Run workflow** | yes | yes | your choice |

The build job is gated behind `if: startsWith(github.ref, 'refs/tags/v') ||
github.event_name == 'workflow_dispatch'`, so everyday pushes only run tests and
never need signing credentials. The upload decision is made in shell rather than
a GitHub expression, because the *string* `"false"` is truthy in those — the
earlier version would have uploaded even with the checkbox cleared.

## Signing: all Release configurations are manual

Every target's **Release** configuration pins `CODE_SIGN_STYLE: Manual` with an
explicit App Store profile. This is not a preference — automatic signing on
media resolves `iOS Team Provisioning Profile: …`, a *development* profile, and
then signs with the Apple Development identity whose key cannot be unlocked in
a headless session (`errSecInternalComponent`). That failed every release until
it was pinned.

| Target | Profile |
| --- | --- |
| StatusBoard-iOS | Status Board iOS App Store |
| Widgets-iOS | Status Board iOS Widgets App Store |
| StatusBoard-watchOS | Status Board Watch App Store |
| Widgets-watchOS | Status Board Watch Widgets App Store |
| StatusBoard-tvOS | Status Board tvOS App Store |
| StatusBoard-macOS | Status Board macOS App Store |
| Widgets-macOS | Status Board macOS Widgets App Store |

`Scripts/fetch-profiles.py` downloads every `Status Board *` profile from App
Store Connect at build time with the API key already on the runner, so profiles
are not secrets and a renewal needs no rotation.

## Adding an entitlement is a portal change too

A provisioning profile is a **snapshot of its App ID taken the day it was
issued**. It carries the capabilities that were enabled at that moment and never
learns about later ones, so an entitlement added in a commit does not reach the
build by being committed. Enable the capability on the identifier and reissue the
profile, or the archive stops with

```
error: Provisioning profile "Status Board iOS App Store" doesn't include
       the com.apple.developer.homekit entitlement.
```

That is not hypothetical: the HomeKit commit failed exactly this way, on all
three profiles that use `guru.am.StatusBoard`, after the unit tests had passed.

Three pieces keep it from happening again, and none of them needs anyone to
remember anything:

| Where | What it does |
| --- | --- |
| `Scripts/signing_spec.py` | Reads project.yml through `xcodegen dump` and says which App ID capability each entitlement needs. An entitlement it has never seen is a **hard error**, not an assumption — guessing "probably harmless" is how HomeKit got through. |
| `Scripts/sync-signing-assets.py` | Enables the missing capabilities, reissues every profile that is stale or short an entitlement, then re-reads the portal to confirm. Idempotent; `--check` reports without changing anything. |
| `Scripts/fetch-profiles.py` | After installing, checks each profile really carries what this commit signs with — seconds, instead of finding out a quarter of an hour into an archive. |

`Scripts/validate-release-configuration.sh` runs the first of those offline,
before any credential is staged, so an unclassified entitlement fails in the
cheapest step of the job. `ci-release.sh` runs the other two on every release.

**So: adding an entitlement to project.yml is now the whole change.** The next
release enables the capability, reissues the profiles and carries on. What still
needs a human is a capability Apple will not turn on blind — iCloud wants its
containers, App Groups its group — and the error says so, names the identifier,
and links the page.

## macOS needs one more certificate

macOS **archives** correctly, but a Mac App Store `.pkg` is signed by a
**Mac Installer Distribution** certificate — a different certificate from the
`Apple Distribution` one that signs the app:

```
error: exportArchive No signing certificate "Mac Installer Distribution" found
```

> **The name in the keychain is not the name in the portal.** App Store Connect
> calls the type `MAC_INSTALLER_DISTRIBUTION` and labels it "Mac Installer
> Distribution", but the certificate it issues has the common name
> **`3rd Party Mac Developer Installer: <team> (<TEAMID>)`**, and that is the
> only name `security find-identity` will ever print. Matching on Apple's label
> finds nothing even when the certificate is correctly installed — which is how
> macOS stayed skipped after the certificate existed.

The certificate does not need the web UI. It is `certificateType`
`MAC_INSTALLER_DISTRIBUTION` on `POST /v1/certificates`, taking a CSR that
`openssl req` can produce, so the same API key that fetches profiles can issue
it:

```bash
openssl req -new -newkey rsa:2048 -nodes -keyout installer.key -out installer.csr \
  -subj "/emailAddress=i@am.guru/CN=AM Guru, LLC/C=US"
```

Post `installer.csr` as `csrContent`, base64-decode `certificateContent` from
the reply into `installer.cer`, and pack the two into a `.p12`. On CI that
`.p12` is the `APP_STORE_INSTALLER_P12_BASE64` secret; it is imported into the
same ephemeral keychain as the distribution certificate and unlocked for
`productbuild`/`productsign` as well as `codesign`.

The secret is **optional**. Without it `release.sh` skips macOS with an
explanation rather than failing the whole release, so iOS and tvOS still ship —
and `validate-release-configuration.sh` prints a line saying macOS will be
skipped, so it does not go unnoticed.

## Still required before CI can cut a release

1. **A distribution signing identity on media.** It currently has only
   `Apple Development: Kalani Helekunihi`. Archiving for the App Store needs
   `Apple Distribution: AM Guru, LLC` *and its private key*, which means
   exporting a `.p12` from the Mac that has it and importing it into media's
   login keychain. Only you can do that — it is private key material.
2. **The tvOS App Store profile**, since tvOS signs manually:
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` on media needs
   `Status Board tvOS App Store`.
3. **The repository secrets** below, including a CloudKit management token so
   CI can prove the Production schema is ready for TestFlight.

## One-time: repository secrets

**Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | Key ID from `~/Repo/appstoreconnect/.env` |
| `ASC_ISSUER_ID` | Issuer ID from the same file |
| `ASC_PRIVATE_KEY` | Full contents of `AuthKey_<KEY_ID>.p8`, including the BEGIN/END lines |
| `DEVELOPMENT_TEAM` | Your 10-character Apple team id |
| `APP_STORE_INSTALLER_P12_BASE64` | Optional. Base64 of the `3rd Party Mac Developer Installer` `.p12`; unlocks the macOS leg. Uses `APP_STORE_DISTRIBUTION_P12_PASSWORD` — it is deliberately not a second password |
| `CLOUDKIT_MANAGEMENT_TOKEN` | Management token from CloudKit Console Settings. `cktool` uses it to inspect the Production schema before release; it is never placed in the app. |

## CloudKit Production is a release prerequisite

Development builds can create `Dashboard.payload` on first write. TestFlight
and App Store builds use CloudKit Production, which will reject that write if
the schema has not been deployed. This is an Apple-side deployment step, not a
board-decoding failure in the app.

Before the first TestFlight release, or after adding a CloudKit record/field:

1. Open CloudKit Console and select `iCloud.guru.am.statusboard`.
2. In **Development**, confirm record type `Dashboard` has a `payload` field of
   type **Bytes**. Running a signed Development build and saving a board creates
   it if necessary.
3. Choose **Deploy Schema Changes…** and deploy it to Production.
4. In CloudKit Console Settings, create a management token and save it as the
   GitHub Actions secret `CLOUDKIT_MANAGEMENT_TOKEN`.
5. Run `Scripts/verify-cloudkit-production-schema.sh` with `APPLE_TEAM_ID` and
   that token in the environment, or start the release workflow. Both inspect
   Production and fail if the required contract is missing.

The release gate checks the server instead of relying on a remembered manual
step. The app also reports missing `Dashboard.payload` explicitly; container,
database, and signing errors have separate messages so they no longer all look
like corrupt board data.

The workflow writes the key to `~/.appstoreconnect/private_keys/` for the build
and deletes it again in an `always()` step, so it never lingers on the runner.

## Running a release

Tag-triggered:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Or **Actions → Build and Release → Run workflow**, choosing platforms
(`both` / `ios` / `macos`) and whether to upload.

## Running a release by hand

The same script CI uses, straight from your Mac or over SSH:

```bash
./Scripts/release.sh --platforms both --upload
```

```bash
ssh media 'cd ~/Repo/StatusBoard && ./Scripts/release.sh --upload'
```

Add nothing and it archives without uploading — useful for a smoke test.

## Where the App Store Connect credentials come from

`Scripts/asc-credentials.sh` resolves them for both `release.sh` and the Python
scripts, first hit wins per value:

1. the environment — `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PATH`
2. `$ASC_ENV_FILE`, default `~/Repo/appstoreconnect/.env`
3. the **login keychain**, service `Status Board: App Store Connect`
4. `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`

Wherever the `.p8` is found it is copied into `~/.appstoreconnect/private_keys`,
because that is the only place `xcodebuild` reads it from (see the gotcha below).

The keychain is the one worth using on a personal machine — it survives a fresh
checkout without leaving the issuer id in a dotfile:

```bash
Scripts/asc-credentials.sh save --key-id ABC1234567 --issuer-id 11111111-2222-3333-4444-555555555555 --private-key ~/Downloads/AuthKey_ABC1234567.p8
```

The key material is stored **base64-encoded**: `security find-generic-password -w`
hex-dumps any value containing a newline, and a PEM is nothing but newlines, so
storing it raw round-trips as an unusable hex string. After saving, the
downloaded `.p8` can be deleted — the resolver writes it back out at `0600` when
a build needs it.

`Scripts/asc-credentials.sh show` prints where each value was found without
printing any of them; `where` prints the issuing page.

### When they are missing

Every entry point prints the page that issues them rather than a bare
"ASC_KEY_ID is required":

<https://appstoreconnect.apple.com/access/integrations/api>
(**Users and Access ▸ Integrations ▸ App Store Connect API**)

- **Issuer ID** — at the top of that page, one per team.
- **Key ID** — the column beside each key.
- **The `.p8`** — offered for download *only* at the moment the key is created.
  Apple never shows it again, so there is nothing to read back out of the web UI
  and no way to recover a lost key; revoke it and generate a new one instead.
  Creating a key needs the Account Holder or Admin role.

That last point is why the scripts read the keychain but do not try to sign in
and scrape: the two identifiers are on the page, but the one value that actually
matters is not, and never will be.

## App Store Connect

| | |
| --- | --- |
| App record | `6798804445` |
| Bundle ID | `guru.am.StatusBoard` (iOS **and** macOS in one record) |
| Widgets | `guru.am.StatusBoard.widgets` |
| SKU | `guru.am.StatusBoard` |

iOS and macOS deliberately share one bundle ID so a single app record — and a
single TestFlight listing — covers both platforms. tvOS
(`guru.am.statusboard.tv`) and watchOS (`guru.am.statusboard.watch`) keep their
own identifiers and are not part of this pipeline yet; a watch-only app needs
its own App Store Connect record.

## One listing, every platform

All five platforms ship from a single App Store Connect record by sharing one
bundle identifier:

| Target | Bundle ID | How it ships |
| --- | --- | --- |
| macOS | `guru.am.StatusBoard` | its own `.pkg` |
| iOS / iPadOS | `guru.am.StatusBoard` | its own `.ipa` |
| tvOS | `guru.am.StatusBoard` | its own `.ipa` |
| watchOS | `guru.am.StatusBoard.watchkitapp` | **embedded inside the iOS `.ipa`** |
| Widgets | `guru.am.StatusBoard.widgets` / `…​.watchkitapp.widgets` | inside their host |

The watch app is a **companion**, not watch-only: its identifier is prefixed by
the iPhone app's, its `Info.plist` carries `WKCompanionAppBundleIdentifier`
(and no `WKWatchOnly`), and XcodeGen's `embed: true` on the iOS target produces
the *Embed Watch Content* phase. That is what allows one TestFlight listing to
cover the watch — a watch-only app would need its own record.

`Scripts/release.sh --platforms all` therefore builds three archives, not five.

## Signing gotchas found on the first real run

**Bundle ID capabilities must be enabled in the portal before archiving.**
Signing will not invent them, and without them the build fails with a wall of
*"… doesn't include the … capability"*. This was a manual step for a year and was
duly forgotten the first time it mattered; `Scripts/sync-signing-assets.py` now
does it on every release — see *Adding an entitlement is a portal change too*.
The identifiers and what they carry are derived from project.yml, so this
paragraph no longer needs a list to go out of date.

**Pass the API key by id, not by path.** `-authenticationKeyPath` makes
xcodebuild fail with *"Authentication failed: Make sure a bearer token was
provided"*. The key has to sit in `~/.appstoreconnect/private_keys/AuthKey_<ID>.p8`
and be referenced with `-authenticationKeyID` / `-authenticationKeyIssuerID`
only. `Scripts/release.sh` copies it there itself.

**The `.env` is parsed, not sourced.** One of its values contains an unquoted
space, which `source` tries to execute.

**`Info.plist` versions must reference build settings, not literals.** XcodeGen
resolves `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` at *generation* time
and would bake `1` into every plist, so `--build-number` never reached the
bundle and the second upload was rejected with *"The bundle version must be
higher than the previously uploaded version: '1'"*. Each `info:` block now sets
`CFBundleVersion: $(CURRENT_PROJECT_VERSION)` and
`CFBundleShortVersionString: $(MARKETING_VERSION)` so Xcode expands them at
build time.

**tvOS signs manually; the other platforms do not.** Automatic signing insists
on a *development* profile when archiving tvOS and then fails with *"Your team
has no devices from which to generate a provisioning profile"* — iOS and macOS
substitute a distribution identity by themselves. Forcing
`CODE_SIGN_IDENTITY = Apple Distribution` while still on automatic signing just
trades that for a *conflicting provisioning settings* error. The working
arrangement is an explicit App Store profile:

```bash
# already created; recreate the same way if it ever expires (2027-07-19)
# POST /v1/profiles  {profileType: TVOS_APP_STORE, bundleId: 2M4MBA8JU3,
#                     certificates: [NWADCF67GA], name: "Status Board tvOS App Store"}
```

The profile is installed into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`,
the tvOS target's **Release** config uses `CODE_SIGN_STYLE: Manual` with that
`PROVISIONING_PROFILE_SPECIFIER`, and `release.sh` writes a matching
`signingStyle: manual` export plist for tvOS only. **A new CI machine needs
that profile installed**, since manual signing will not fetch it.

## Some bundle keys are upload-blocking

Learned the hard way, one rejected upload at a time:

| Key | Where | Why |
| --- | --- | --- |
| `UISupportedInterfaceOrientations` with all **four** orientations | iOS | error 90474 — a universal app must support iPad multitasking |
| `NSHealthUpdateUsageDescription` | iOS, watchOS | error 90683 — required whenever the HealthKit entitlement is present, even though the app only ever reads |
| `LSApplicationCategoryType` | macOS | required for Mac App Store bundles |
| `ITSAppUsesNonExemptEncryption: false` | iOS, macOS | otherwise builds park in "Missing Compliance" and cannot reach testers |
| tvOS Brand Assets | tvOS | Apple TV needs layered `.imagestack` icons plus top-shelf art; the back layer and top shelf must be **fully opaque** |

## A sandboxed Mac app needs the entitlement *and* the usage string

Usage strings alone do nothing on macOS. `NSCalendarsFullAccessUsageDescription`
was set, but the sandbox had no
`com.apple.security.personal-information.calendars`, so EventKit never got as far
as a permission dialog — the sandbox refused the XPC connection to the calendar
daemon and every call failed with:

```
The operation couldn't be completed. (Mach error 4099 - unknown error code)
```

4099 is `MACH_SEND_INVALID_DEST`: a send to a port that was never allowed to
exist. Nothing about it mentions calendars or privacy, and resetting the app's
privacy settings does not help, because no permission was ever requested.
`CalendarSource` now translates an `NSMachErrorDomain` failure into a sentence
that names the cause, so if this ever regresses the panel says so.

Location was already correct here — same rule, quieter failure — and the widget
extensions need nothing, since they render stored snapshots and never call
EventKit themselves.

## Before the first upload

1. `DEVELOPMENT_TEAM` is read from `project.yml` when it is not in the
   environment, so a local run needs no extra setup.
2. Age rating and privacy policy URL are set (see below). Internal TestFlight
   testing works as soon as a build finishes processing.
3. `CFBundleShortVersionString` comes from `MARKETING_VERSION` in
   `project.yml`; the build number is generated as `YYMMDD.R` per run.

## Store metadata already configured

| | |
| --- | --- |
| Category | Productivity / Utilities |
| Age rating | Answered honestly; `unrestrictedWebAccess = true` because Web Clip panels load any URL the user enters |
| App Privacy | **Data Not Collected**, published |
| Privacy policy | `https://am-guru.github.io/StatusBoard/privacy.html` |
| Support | `https://github.com/AM-Guru/StatusBoard/issues` |
| Marketing | `https://am-guru.github.io/StatusBoard/` |
| Beta review contact | Kalani Helekunihi, i@am.guru — no demo account required |

The two URLs above are served by **GitHub Pages from the `docs/` folder** on
`main`. They only resolve once the repository is pushed and Pages is enabled
(Settings → Pages → Source: Deploy from a branch → `main` / `/docs`). Internal
TestFlight does not check them; App Review does.
