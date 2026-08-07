# App Store screenshots

Regenerates the App Store Connect screenshot sets for every platform, in the
Slaptop house style: a coloured gradient field, a product eyebrow, one big
headline, a subhead, body copy, two how-to lines, and the real app inside a
device bezel.

Output lands in `Distribution/AppStore/Screenshots/<platform>/`.

## Running it

```bash
Scripts/screenshots/make.sh
```

That is the whole pipeline. It expects the simulators listed in
`capture_boards.sh` to be booted and the app installed on them, and a macOS
build at `build/dd-mac/Build/Products/Debug/Status Board.app`.

To rebuild just the frames after editing copy — no simulators involved:

```bash
python3 Scripts/screenshots/compose.py <raw-dir> Distribution/AppStore/Screenshots
```

## The pieces

| File | What it does |
| --- | --- |
| `seed_demo_data.py` | Writes the six demo boards and their snapshots into a container |
| `seed_simulator.sh` | Runs the seeder against one simulator, app terminated first |
| `capture_boards.sh` | One raw capture per board, per simulator |
| `capture_mac.sh` | Same for the macOS app, capturing the window by id |
| `window_bounds.swift` | Prints a Mac window's id and bounds (no permissions needed) |
| `shots.json` | Every frame: platform, source capture, and all its copy |
| `compose.py` | Draws the finished frames at App Store Connect's exact sizes |

## Canvas sizes

| Platform | Pixels | Device captured |
| --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max |
| iPad 13" | 2064 × 2752 | iPad Pro 13-inch (M5) |
| macOS | 2880 × 1800 | 1440 × 900 window on a Retina display |
| Apple TV | 3840 × 2160 | Apple TV 4K (3rd generation) |
| Apple Watch | 416 × 496 | Series 11, 46 mm |

## Things that will bite you

**Demo data, not real data.** Every panel that would otherwise need a
credential is a `bridge` panel. `PanelKind.isFetched` is false for that kind,
which is the only reason `DataSourceEngine` doesn't replace the seed with a
"not configured" error a second after launch. Weather and the clocks are
genuinely live.

**Never seed the release Mac app.** It is sandboxed and its boards live in
`~/Library/Containers/guru.am.StatusBoard/…` — somebody's real dashboards.
`capture_mac.sh` runs a development build, which is unsandboxed and uses
`~/Library/Application Support/StatusBoard` instead.

**tvOS and watchOS drop boards they were never sent.** They can't author
boards, so `DashboardStore.load()` treats `dashboards.json` as a cache of
iCloud and filters it against `icloud-boards.json`. The seeder writes that
file too; without it those two launch to an empty shelf.

**Board order picks the shot.** `load()` selects `dashboards.first`, so
`--first "Mac Vitals"` launches straight into that board. That is why this
pipeline barely taps anything.

**Don't use AppleScript on the Mac app.** System Events needs Accessibility
permission and hangs waiting for it in a non-interactive session.
`window_bounds.swift` reads `CGWindowList`, which needs nothing, and
`screencapture -l<id>` grabs the window directly.

**`clockStyle` is deliberately absent from the seed.** It is a young field,
and a build that doesn't know a raw value throws on decode and takes every
board down with it. Leaving it out lets each build apply its own default.
