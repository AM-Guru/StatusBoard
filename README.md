# Status Board

A self-hosted dashboard for Apple devices, in Swift + SwiftUI for **macOS,
iPhone, iPad, Apple TV and Apple Watch**. Build boards from live panels, clip a
region of any web page, wire in the services you already run, and push your own
values straight from the terminal — with iCloud sync between your own devices, a
Mac "bridge" for terminal and AI tooling, MCP integrations, Shortcuts actions
and WidgetKit widgets everywhere.

No account, no analytics, no server: the app has zero external dependencies and
the developer has no way to see your data.

![Platforms](https://img.shields.io/badge/platforms-macOS%2015%20·%20iOS%2018%20·%20tvOS%2018%20·%20watchOS%2011-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

<https://statusboard.am.guru>

## Features

**Panels** (add as many as you like, drag to move, drag the corner to resize):

| Panel | What it shows |
|---|---|
| Clock | Big LCD-style clock, any time zone |
| Weather | Current conditions + 5-day forecast (Open-Meteo, no API key) |
| Graph | 12 chart styles — line, smooth, area, bars, lollipop, strip, delta, threshold, peak, radial, waveform, matrix heatmap — from a JSON URL **or** live bridge data |
| Progress | 0–100% in 7 formats: bar, ring, watch dial, dots, stack, matrix, gradient |
| RSS Feed | Headlines from any RSS/Atom feed — list or big rotating **ticker** |
| Calendar | Upcoming events from the system calendar; the latest event feed syncs through private iCloud for Apple TV |
| Web Clip | A live web page, or **just a region of one** (see below); the Mac bridge renders and crops it for Apple TV |
| Image | A fetched image with optional Core Image filter chains (`sepia:70,blur:20`, pixelate, grayscale, invert) |
| Table | JSON/CSV tables with zebra striping and semantic status coloring (`success`/`degraded`/`failed`/`building`…) |
| Service Status | Up/degraded/down pings for your endpoints, with latency |
| Countdown | Days/hours/minutes/seconds to a date |
| Text | Static text |
| MCP Tool | The result of a Model Context Protocol tool call |
| Bridge Value | Anything pushed from the terminal via the Mac bridge |
| GitHub | Actions workflow runs, open issues/PRs, latest release, or stars for any repo |
| App Store Connect | Your apps, TestFlight builds, or customer reviews (signed ES256 API requests) |
| Supabase | PostgREST table queries, or arbitrary SQL via the management API |
| Web Logs | Apache/nginx access-log analytics: hourly traffic, top paths, status mix |
| Health | Steps, active energy, exercise minutes, heart rate, or last night's sleep from HealthKit (iPhone/iPad/Watch) |
| Canvas | Instructure Canvas: assignments due today, late/missing work, upcoming week, and current grade per course |
| K12 Class Schedule | Class meeting times from the K12/Stride portal: today's classes with times and attendance, next class, or the week ahead |
| Grades | Every class with its current score, colour-graded and ranked |
| Schedule | The classes left today, with a live countdown, teacher, and a tap-to-join link |
| Assignments | Due today, late, and a Re-Do list of work graded below full marks |
| Home (HomeKit) | Room temperatures, any sensor you pick, motion/doors/locks, a thermostat, its trend, its equipment health, or a live camera — from accessories already paired to your Apple ID (iPhone/iPad/Apple TV/Watch) |
| Home Assistant | The same seven views, read from your own server over its REST API — grouped by the areas you already defined, with camera snapshots and trend history backfilled from its recorder |
| Nest Thermostat | Ambient temperature, setpoint, mode and equipment status per thermostat, plus trend and health, through Google's Smart Device Management API |

- **Web clip region picker**: browse any page inside the app, sign in if needed
  (Browse mode shares cookies with the panels), then tap the element you want to
  show. **Narrower / Wider** walk the selection in and out through the element
  tree — Wider steps to the parent, Narrower into the largest child — with the
  live size readout so you can land exactly on the region you mean, and
  **Preview** shows the finished clip with the picker chrome out of the way.
  Hide Elements mode removes anything you don't want, and each hidden element
  can be restored individually.
- **Saved sign-in for web clips** — clips of pages behind a login can sign
  themselves in, and log back in automatically if the site redirects them to
  the login page (stopping after three failed tries). Credentials go in the
  **Keychain**, keyed to that page's host — never in the dashboard JSON, so they
  are never synced, exported, or shared along with a board.
- **Ad and tracker blocking** in web clips, built on **EasyList** and
  **EasyPrivacy** — the same
  — the open-source lists Adblock Plus and uBlock Origin build on. Filters are
  converted to WebKit's native content-blocker format and compiled with
  `WKContentRuleListStore`, so blocking happens in the engine rather than by
  injecting scripts. A built-in list covers the major ad, tracking and
  cookie-banner networks offline; the full EasyList downloads and caches in the
  background. Toggle per panel.
- **Multiple dashboards**, synced across devices via **CloudKit** (CKSyncEngine).
- **Per-device layouts** — one board, arranged differently per screen. A 16:9 TV
  across the room and a phone in your hand rarely want the same grid, so each
  device class (Mac, iPad, iPhone, Apple TV, Watch) can carry its own panel
  positions, grid size, and hidden panels — **per orientation** on the screens
  that turn, so an iPhone on its side and an iPhone upright are arranged
  separately. The Mac, iPad landscape and Apple TV follow the board's shared
  layout until you customize them. The narrow screens don't: an **iPhone and an
  Apple Watch arrange themselves in a single column**, and an upright iPad in
  four, reflowing the board in reading order rather than squeezing eight columns
  into a hand. Charts, feeds and tables take a whole row rather than a sliver.
- **Boards scroll** on Mac, iPad and iPhone. A row is never drawn shorter than
  the screen can read, so a board with more rows than fit runs past the bottom
  and scrolls instead of shrinking every panel into an unreadable strip. The
  Apple TV is the exception — nobody scrolls from the sofa, so its board always
  fits the screen exactly.
- **Screen menu** on Mac, iPad and iPhone (toolbar dropdown beside Edit) — pick
  This Mac, iPad, iPhone, Apple TV, Apple Watch or a linked pair of **Smart
  Glasses** and the whole window becomes
  that screen's layout editor: no modal, the board gets the full window. The
  board is laid out at the target screen's real point size and then scaled to
  fit, so panel text shrinks in proportion and you can tell what will be legible
  from the couch. Drag and resize panels, toggle individual panels off per
  device, switch between **Portrait and Landscape** for the iPhone and iPad, set
  that screen's grid, Auto-Arrange, or copy another device's
  arrangement — the options column hides with ⇧⌘D when you want the whole window
  for the board. The Apple TV layout also draws a **TV-safe guide**: anything
  outside the dashed line is at risk of being cropped by the television's
  overscan.
- **Zoomable device previews** — pinch or use the 50–300% preview slider while
  arranging another screen, then scroll around the target canvas. Zoom is only
  an editing aid and never changes the saved layout.
- **Board content scaling** — choose 75–200% content size; scrolling platforms
  grow and scroll instead of clipping, while Apple TV stays inside its safe area.
- **Smart glasses** — Status Board doesn't run on a pair of Even Realities G2s;
  [SybilSight](https://sybilsight.com) does, and it draws Status Board's boards
  on the lenses. Turn the Mac bridge on, switch Status Board on in SybilSight,
  and the phone subscribes to this Mac exactly the way an Apple TV does — over
  Bonjour on the local network, no account, nothing leaving the house. Once it
  has, a **Smart Glasses** entry appears in the screen menu and arranges the real
  canvas: 576×288, one pixel per point, drawn in the single green a waveguide
  emits so you can see before it reaches somebody's face that the amber accent
  and the teal accent are now the same colour. A dashed **lens-safe guide** marks
  the eyebox, and the panels a monochrome strip can't carry — web clips, images,
  MCP results — are named and left out rather than sent as grey mush. The screen
  is only offered while a pair is linked; there is a switch in the same menu to
  arrange one before you have ever connected it.
- Classic touches: triple-tap a panel to force-reload it; share a board as JSON
  from the toolbar.
- **Per-panel accent colors** — pick any color in a panel's Appearance section;
  charts, progress rings, clocks, and big numbers all follow it.
- **Threshold alerts** — set "notify above/below" limits on numeric panels;
  you get a local notification when a value crosses the line and again when it
  recovers (15-minute cooldown).
- **Graphs of anything** — a Graph panel with a JSON URL and a value path
  samples one number per refresh and charts its accumulated history.
- **Lock Screen widgets** on iOS (inline, circular gauge, rectangular) plus the
  Home Screen/desktop widget families. Every panel kind is eligible, including
  static clocks, countdowns, and text; widgets resolve the source board's theme
  unless the panel keeps a fixed theme of its own.
- **Shared panels across dashboards** — place one panel on several boards from
  its context menu. Its title, source settings, data, and appearance update as
  one, while every board and device keeps its own frame. Choose “Make
  Independent” to fork one placement. A shared panel set to the Status Board
  theme adopts each board's theme; an explicit panel theme stays fixed.
- **Apple TV menu** — swipe down (or click) for a ten-foot menu that picks which
  of your iCloud-synced boards this Apple TV shows. The choice is remembered per
  device, so each screen in the house can sit on its own board, and it is
  restored even when that board only arrives from iCloud after launch. The menu
  also shows iCloud sync status with a "Check iCloud for Boards" action,
  auto-cycling through boards on a timer, wall-display style, and a **Screen
  Fit** choice — boards stay inside the TV-safe area by default so overscan
  can't crop a panel, or fill the whole screen on a display that shows every
  pixel. An Apple TV also checks iCloud on its own — hard while the screen is
  empty, then every quarter hour — because a wall display has nobody standing
  at it to pull for a refresh.
- **Boards over the local network** — an Apple TV or Watch subscribed to the
  Mac bridge receives its boards straight from that Mac, and follows edits made
  there live. No iCloud account, no CloudKit container, nothing leaving the
  house. It runs alongside iCloud rather than instead of it: a board made on
  your iPhone still arrives over iCloud even if the Mac has never seen it.
  Devices that author their own boards (Mac, iPad, iPhone) ignore boards
  offered by a bridge, so joining one for panel data can't overwrite your work.
- **Apple Watch app + complications** — browse panels, tap for full-screen live
  views, and put any panel on your watch face (inline, circular, rectangular,
  and corner complications). Dashboards arrive via iCloud; URL panels fetch
  right on the watch.
- **Shortcuts actions** — "Push Value to Status Board" feeds any key from any
  automation (no bridge needed; numeric pushes build chartable history), and
  "Get Status Board Value" reads panel values for use in automations. Values
  pushed while the app is closed spool and appear on widgets immediately.
- **Share as image** — export any board as a rendered 1080p poster from the
  Share menu, alongside JSON export.
- **Live Activities** — pin any numeric panel to the iPhone Dynamic Island and
  Lock Screen from its settings sheet; the value updates live as bridge pushes,
  fetches, and Shortcuts pushes arrive.
- **Control Center & Focus** — an iOS 18 Control Center button opens the app,
  and a Focus filter can switch the visible dashboard per Focus mode ("Work
  Focus shows the Ops board").
- **Sample boards** — the New Board menu includes curated starters: a Mac
  Vitals monitoring wall and a color-coded World Clocks board.
- **Accessible by design** — every panel is a single VoiceOver element that
  speaks a written summary of its data ("Services. Web down, CDN degraded",
  "CPU. 67 percent", "Latest 40 percent, 12 points, trending up") instead of
  exposing unlabeled chart shapes. Ticker animation respects Reduce Motion.
- **Undo/redo** — panel and board edits (add, delete, move, resize, configure)
  are undoable with ⌘Z / ⇧⌘Z, with named actions like "Undo Delete Weather".
  Edits arriving from iCloud never enter your local undo history.
- **Keyboard shortcuts** — ⌘N new board, ⌘E edit layout, ⌘R refresh all,
  ⌘Z/⇧⌘Z undo/redo, ⌘D duplicate panel, ⇧⌘C/⇧⌘V copy and paste panels, plus a
  full Board menu on the Mac and the iPad's hold-⌘ shortcut sheet.
- **Duplicate and copy/paste panels** — right-click (or long-press) any panel
  for Configure / Refresh / Duplicate / Copy / Delete. Copied panels travel as
  readable JSON on the system pasteboard, so Universal Clipboard moves a
  configured panel from your iPhone to your Mac, and pasting into a text editor
  gives you a shareable panel definition.
- **Spotlight & Handoff** — boards and panels are indexed with their latest
  values, so searching "CPU" from the Home Screen or ⌘-Space jumps straight to
  the board; the visible board is published for Handoff to your other devices.
- **Boards stop at their content** — empty rows below the last visible panel are
  not drawn or scrolled. A full fixed grid is not silently stretched; a newly
  added panel is selected above the least-crowded area so the user can decide
  which layout should move.
- **Clips survive re-renders** — region isolation works by hiding siblings up
  the ancestor chain and neutralizing their layout, so the region is promoted to
  the top of the page rather than scrolled to. A MutationObserver re-applies it
  when single-page apps re-render.
- **Web queries**: fetch any JSON API and extract values with dot paths
  (`data.items[*].price`, wildcards and negative indices supported).
- **Mac bridge**: the macOS app runs a Bonjour-advertised server that accepts
  pushes from shell scripts, CI, and AI tools, and relays them live to every
  iPhone/iPad/Apple TV on the network. It also relays values fetched by the Mac
  itself (including Calendar), hands its boards and cached values to newly
  connected displays, and renders web clips offscreen for tvOS (which has no WebKit).
- **MCP client**: panels can call tools on MCP servers over streamable HTTP
  (all platforms) or stdio (macOS spawns the server process).
- **Widgets**: a configurable WidgetKit widget (iOS + macOS) shows any panel's
  latest data on your Home Screen / desktop.

## Repository layout

```
project.yml                     XcodeGen project definition
Apps/
  macOS/  iOS/  tvOS/           Thin app shells (@main + scenes)
  Widgets/                      WidgetKit extension (shared by iOS + macOS targets)
Packages/StatusBoardKit/        Everything else — models, stores, sync,
                                data sources, bridge, MCP, and all SwiftUI views
    Sources/sbctl/              Terminal CLI for pushing data to the bridge
website/                        statusboard.am.guru — no build step; pushing to
                                main publishes it (docs/website.md)
docs/                           CI, release and API notes
```

## Building

Requirements: Xcode 26+ (SDKs for macOS 15 / iOS 18 / tvOS 18), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open StatusBoard.xcodeproj
```

Schemes: `StatusBoard-macOS`, `StatusBoard-iOS`, `StatusBoard-tvOS`,
`StatusBoard-watchOS` (widget extensions build/embed automatically).

Run the package tests:

```bash
cd Packages/StatusBoardKit && swift test
```

### Signing & iCloud setup

1. Set your team once in `project.yml` (`DEVELOPMENT_TEAM`) or in Xcode's
   Signing & Capabilities editor, then regenerate/build.
2. The bundle IDs default to `guru.am.statusboard.*` with the iCloud container
   `iCloud.guru.am.statusboard` and App Group `group.guru.am.statusboard`.
   Rename them in `project.yml` **and** in
   `Packages/StatusBoardKit/Sources/StatusBoardKit/Store/AppGroup.swift`
   (`SBIdentifiers`) if you use your own prefix.
3. The CloudKit schema is created automatically on first sync (one record type,
   `Dashboard`, in a private zone). Unsigned/entitlement-less dev builds detect
   the situation and simply run with sync off.

## The Mac bridge

The macOS app starts a bridge server on port **7311**, controllable from the
Bridge Console window or the **menu bar extra**.

**Zero-setup system metrics:** while the bridge runs, the Mac automatically
publishes its own vitals every 5 seconds — `mac.cpu`, `mac.memory`, `mac.disk`,
`mac.net.in`, `mac.net.out` (each with a `.history` series for graphs) and
`mac.uptime`. Point any Graph, Progress, or Bridge Value panel at those keys on
any device and you have a live Mac monitoring wall with no scripting at all.
Turn it off in the Bridge Console if you prefer.

The server is configurable in the Bridge Console window. An optional shared
secret protects both data pushes and device subscriptions; enter the same token
in Apple TV's bridge settings. Devices discover it via Bonjour
(`_statusboard._tcp`) and subscribe over TCP; every push is relayed instantly.

Push from any terminal, script, cron job, or AI tool:

```bash
# A number with rolling history — graph panels can chart "cpu.history"
curl -X POST http://localhost:7311/api/push \
     -d '{"key":"cpu","number":42.5,"unit":"%","history":120}'
```

```bash
# Text, tables, feeds, and statuses work too
curl -X POST http://localhost:7311/api/push \
     -d '{"key":"deploys","text":"v1.2.3 shipped"}'
```

Inspect state:

```bash
curl http://localhost:7311/api/health
```

```bash
curl http://localhost:7311/api/keys
```

### sbctl

A small CLI is included in the package:

```bash
cd Packages/StatusBoardKit && swift build -c release --product sbctl
```

```bash
sbctl push --key cpu --number 42.5 --unit % --history 120
```

```bash
# Stream numbers from any tool straight onto your dashboards
while true; do ps -A -o %cpu | awk '{s+=$1} END {print s}'; sleep 2; done | sbctl pipe --key cpu
```

Then add a **Graph** panel with bridge key `cpu.history`, or a **Bridge Value**
panel with key `cpu` — every device shows it live.

## MCP panels

Add an **MCP Tool** panel and configure:

- **HTTP transport** (all platforms): the server URL of any streamable-HTTP MCP
  server, plus optional headers.
- **stdio transport** (macOS): a command such as `npx` with arguments — the Mac
  spawns the server and speaks JSON-RPC over stdin/stdout.

The panel calls the configured tool on the panel's refresh interval and renders
the result (numbers become big LCD digits; text renders as monospace).

## Widgets

Add the "Status Board Panel" widget on iOS, macOS, or a watch face and choose
any panel from its configuration. Widgets read the latest snapshots and panel
metadata from the shared App Group, so they keep showing data when the app is
closed. Clock, countdown, and text panels render from their settings without a
snapshot. A panel on its default theme adopts the selected board's theme; a
panel with an explicit theme keeps that fixed appearance.

## School panels

Three purpose-built panels sit on top of the Canvas and K12 connectors:

- **Grades** — one row per active course: a colour-coded letter badge, a bar
  showing where the score sits, and the percentage. Ranked best-to-worst, with
  colour running green → amber → red so a whole term reads at a glance. Tap a
  row to open that course's grade page.
- **Schedule** — only the classes *still to come* today, each with its start
  time and a live countdown ("in 1h 14m"), the teacher, and a REQUIRED badge
  when attendance is mandatory. A class in session is highlighted and marked
  "● now" with a join button. When everything's finished it says so; when
  there was never anything scheduled, it's a day off.
- **Assignments** — split into **Late**, **Due Today**, and **Re-Do**. Work
  finished at full marks is hidden, and so is anything handed in and waiting on
  a grade (counted in a footer instead). Once graded, anything below full marks
  drops into Re-Do showing the score it got — "13/20 · 65%" — with a link
  straight to the assignment.

All three accept **class aliases**: rename "AP US History A (Sem 1)" to
"History" in the panel's settings and every panel uses the short name. The
settings list the classes from your current data, so there's nothing to type
from memory.

## Connectors

The GitHub, App Store Connect, Supabase, Canvas, and Web Logs panels talk to
their services directly from each device:

- **Canvas** — enter your institution's Canvas URL and a personal access token
  (Canvas → Account → Settings → "+ New Access Token"). *Due Today* and
  *Upcoming* list outstanding assignments with their course and due time (late
  ones flagged), *Late / Missing* uses Canvas's missing-submission list and
  falls back to planner submission flags for schools that don't populate it,
  and *Current Grades* shows the running score and letter grade per course.
- **K12 Class Schedule** — for K12/Stride schools, class meeting times live in
  the Launch Pad portal rather than Canvas. You sign in **once** from the
  panel's settings; after that the panel calls the portal's API directly over
  the network — no embedded web page — so it's fast enough for widgets and
  background refreshes. Four views: today's classes with times, teacher and
  required/optional attendance; the next (or currently live) class; the week
  ahead; and courses with teachers and grades. See
  [docs/k12-canvas-ols-api.md](docs/k12-canvas-ols-api.md) for the reverse
  engineered API notes behind both panels.

- **GitHub** — repository `owner/name`; a token is only needed for private
  repos. Workflow-run tables use the status colors (`success`, `failed`,
  `running`, `pending`).
- **App Store Connect** — create an API key in Users and Access, then paste the
  key ID, issuer ID, and the `.p8` contents. Requests are signed on-device with
  an ES256 JWT. Secrets live in your dashboards, which sync only through your
  private CloudKit database.
- **Supabase** — Table mode wants the project URL, an API key, and a PostgREST
  query (`todos?select=*&limit=20`). SQL mode wants the project ref and a
  personal access token, and runs through the management API. Single values
  render as big numbers, label+value pairs as charts, everything else as tables.
- **Web Logs** — point it at an access log in combined format. For local files,
  serve the file over HTTP or stream it through the bridge
  (`tail -f access.log | sbctl pipe --key weblog`).

## Home panels

Three providers, one set of panels. Each panel picks a **mode** — Room
Temperatures, Sensors, Motion & Doors, Thermostat, Temperature Trend, Equipment
Health, or Camera — and the provider answers it. A HomeKit thermostat, a Home
Assistant `climate` entity and a Nest unit are normalized to the same reading,
so they render identically and can sit side by side on one board.

- **HomeKit** needs no setup at all: it reads the accessories already paired to
  your Apple ID, and only reads — it never controls anything. There is **no
  HomeKit framework on macOS**, so add these panels on an iPhone, iPad or Apple
  TV; the latest non-camera reading follows the panel through the user's private
  CloudKit database, so a Mac can display it. Equipment history and camera
  frames never sync. Health values remain device-local unless the user explicitly
  enables “Sync Latest Value with Private iCloud” on that Health panel.
- **Home Assistant** wants your server's address and a long-lived access token
  (profile ▸ Security). Rooms come from Home Assistant's own **areas**, read
  over the REST API via a rendered template, so nothing has to be typed twice.
  It's also the only provider with history: a new trend panel backfills from
  the recorder instead of starting blank.
- **Nest** goes through Google's Smart Device Management API, which needs a
  [Device Access](https://developers.google.com/nest/device-access) project (a
  one-time $5 registration with Google) and an OAuth client of type *Web
  application*. Connect the account from the panel's settings: it opens
  Google's consent page in your real browser — Google blocks embedded web views
  for sign-in — and you paste the resulting address back. Two limits are
  Google's, not ours: **Nest Temperature Sensors are not exposed** by the API
  (only thermostats are, so "per room" means per thermostat), and Nest cameras
  are offered as a WebRTC stream rather than an image, so there is no Nest
  camera panel. If you run Home Assistant, its Nest integration exposes those
  cameras as ordinary snapshot entities the Home Assistant panel can show.

**Equipment health** is the part none of the three services provides. Status
Board records a sample every refresh, keeps about a week of them on the device,
and works out cycles per hour, average run length, runtime share, and warnings:
short cycling, running without closing the gap to the setpoint, a room moving
the *wrong way* while the system runs, near-constant runtime, high humidity
while cooling, and a wide swing on a steady setpoint. Every warning quotes the
numbers behind it, and nothing is claimed before there's about an hour of
history. Short runs are only visible if the panel refreshes at least as often as
they last, so home panels default to a **one-minute** refresh (Nest to three, to
stay inside Google's quota).

## Notes

- Web clips on Apple TV are rendered to images by the Mac bridge (tvOS has no
  WKWebView) — keep the Mac app running for those panels.
- The iOS app keeps the screen awake so a board stays readable.
- `NSAllowsArbitraryLoads` is enabled so web clips/feeds/queries can use
  plain-HTTP endpoints (e.g. homelab dashboards); remove it from `project.yml`
  if you only need HTTPS.

## Contributing

Pull requests are welcome.

`main` is protected: it takes signed commits from the repository owner only, so
every other change arrives through a pull request. Sign your commits (`git
commit -S`, or turn on `commit.gpgsign`) and keep `swift test` green —
`Packages/StatusBoardKit` is where the logic and the tests live.

The Xcode project is generated: edit `project.yml` and run `xcodegen generate`
rather than editing `StatusBoard.xcodeproj`, which is not tracked.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Kalani Helekunihi.
