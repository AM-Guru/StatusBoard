#!/usr/bin/env python3
"""Write a demo dashboards.json + snapshots.json into a StatusBoard container.

App Store screenshots need boards that look lived-in, and the real data
sources need credentials nobody should put in a marketing shot. So this
writes a fixed set of boards whose data-bearing panels are `bridge` panels —
the one kind `PanelKind.isFetched` says false for, which is what stops
`DataSourceEngine` replacing the seed with a "not configured" error the
moment the app launches.

Usage:
    seed_demo_data.py <container-dir>          # writes both files
    seed_demo_data.py --list                   # print the board names

<container-dir> is the directory holding dashboards.json, i.e.
"<app data container>/Library/Application Support/StatusBoard".
"""

from __future__ import annotations

import json
import math
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

# A fixed namespace so every run produces the same ids: reseeding a simulator
# must not orphan the snapshots keyed by panel id.
NS = uuid.UUID("5b2d9a1e-6c34-4f7a-9d21-0c8f4b5e7a10")


def pid(name: str) -> str:
    return str(uuid.uuid5(NS, name)).upper()


NOW = datetime(2026, 8, 7, 16, 20, 0, tzinfo=timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# panel/board builders
# --------------------------------------------------------------------------

def appearance(**kw):
    """A panel appearance with the same defaults the Swift struct encodes."""
    base = {
        "animates": True,
        "backgroundBlur": 0,
        "backgroundOpacity": 1,
        "backgroundStyle": "theme",
        "borderWidth": 1,
        "contentOpacity": 1,
        "cornerRadius": 14,
        "dynamicIntensity": 1,
        "glowRadius": 0,
        "gradientAngle": 135,
        "gradientColorHexes": [],
        "imageFill": "fill",
        "material": "none",
        "scrim": 0,
    }
    base.update(kw)
    return base


def settings(**kw):
    """PanelSettings with the defaults the app writes out.

    Deliberately omits `clockStyle`: it is a young field and an older build
    reading an unknown raw value fails the whole decode, taking every board
    with it. Leaving it out lets each build apply its own default.
    """
    base = {
        "calendarDaysAhead": 7,
        "chartStyle": "line",
        "courseAliases": {},
        "feedShowsSourceIcons": True,
        "feedShowsSourceNames": True,
        "feedSources": [],
        "healthMetric": "steps",
        "listDisplay": "list",
        "progressFormat": "bar",
        "refreshSeconds": 300,
        "showsSeconds": True,
        "statusTargets": [],
        "tableHasHeader": True,
        "tableStatusColoring": True,
        "tableZebra": True,
        "tessieAutoContext": True,
        "tessieContext": "parked",
        "tessieDrivingFields": ["speed", "navigation", "map", "arrival", "battery", "range"],
        "tessieParkedFields": ["battery", "charging", "map", "location", "lock", "sentry", "climate"],
        "weatherLocationMode": "coordinates",
        "weatherPersonalFormat": "automatic",
        "weatherPersonalPaths": {},
        "weatherStationNetwork": "nws",
        "weatherUnits": "automatic",
        "webClipAutoLogin": False,
        "webClipBlocksAds": True,
        "webClipHideSelectors": [],
        "webClipZoom": 1,
    }
    base.update(kw)
    return base


def panel(key, kind, title, x, y, w, h, **st):
    return {
        "id": pid(key),
        "kind": kind,
        "title": title,
        "frame": {"x": x, "y": y, "width": w, "height": h},
        "settings": settings(**st),
    }


def board(name, columns, rows, theme, wallpaper, panels, spacing=12, **appkw):
    app = {
        "animates": True,
        "appliesThemeToPanels": True,
        "backgroundBlur": 0,
        "backgroundOpacity": 1,
        "gradientAngle": 135,
        "gradientColorHexes": [],
        "imageFill": "fill",
        "panelSpacing": spacing,
        "scrim": 0,
        "theme": theme,
        "wallpaper": wallpaper,
    }
    app.update(appkw)
    return {
        "id": pid("board:" + name),
        "name": name,
        "grid": {"columns": columns, "rows": rows},
        "appearance": app,
        "deviceLayouts": {},
        "createdAt": iso(NOW - timedelta(days=40)),
        "modifiedAt": iso(NOW),
        "panels": panels,
    }


# --------------------------------------------------------------------------
# boards
# --------------------------------------------------------------------------

def home_board():
    """The hero board: the house, the sky, the day."""
    ps = [
        panel("home/weather", "weather", "Weather", 0, 0, 4, 2,
              latitude=37.7749, longitude=-122.4194, locationName="San Francisco",
              appearance=appearance(hidesTitleBar=True, dynamic="weather",
                                    backgroundStyle="clear", borderWidth=0,
                                    cornerRadius=18)),
        panel("home/clock", "clock", "Clock", 4, 0, 2, 1, showsSeconds=False),
        panel("home/countdown", "countdown", "School Starts", 6, 0, 2, 1,
              targetDate=iso(NOW + timedelta(days=11, hours=3))),
        panel("home/thermostat", "bridge", "Thermostat", 4, 1, 2, 1,
              bridgeKey="demo.thermostat"),
        panel("home/rooms", "bridge", "Rooms", 6, 1, 2, 1,
              bridgeKey="demo.rooms"),
        panel("home/cpu", "graph", "Mac CPU", 0, 2, 5, 2,
              bridgeKey="mac.cpu.history", chartStyle="area"),
        panel("home/doors", "bridge", "Doors & Windows", 5, 2, 3, 2,
              bridgeKey="demo.contacts"),
    ]
    return board("Home", 8, 4, "board", "none", ps, spacing=12)


def family_board():
    """School: what is graded, what meets today, what is owed."""
    ps = [
        panel("school/grades", "bridge", "Grades", 0, 0, 4, 2,
              bridgeKey="demo.grades"),
        panel("school/schedule", "bridge", "Today's Classes", 4, 0, 4, 2,
              bridgeKey="demo.schedule"),
        panel("school/assignments", "bridge", "Assignments", 0, 2, 5, 2,
              bridgeKey="demo.assignments"),
        panel("school/break", "countdown", "Winter Break", 5, 2, 3, 1,
              targetDate=iso(NOW + timedelta(days=134))),
        panel("school/clock", "clock", "Clock", 5, 3, 3, 1, showsSeconds=False),
    ]
    return board("School", 8, 4, "aurora", "dusk", ps, spacing=14)


def vitals_board():
    """Every renderer the progress and chart families can draw."""
    ps = [
        panel("mac/cpu", "progress", "CPU", 0, 0, 2, 1,
              bridgeKey="mac.cpu", progressFormat="circle"),
        panel("mac/mem", "progress", "Memory", 2, 0, 2, 1,
              bridgeKey="mac.memory", progressFormat="gradient"),
        panel("mac/disk", "progress", "Disk", 4, 0, 2, 1,
              bridgeKey="mac.disk", progressFormat="dots"),
        panel("mac/up", "progress", "Network", 6, 0, 2, 1,
              bridgeKey="mac.net.in", progressFormat="matrix"),
        panel("mac/cpuhist", "graph", "CPU · 30 min", 0, 1, 4, 2,
              bridgeKey="mac.cpu.history", chartStyle="waveform"),
        panel("mac/memhist", "graph", "Memory · 30 min", 4, 1, 4, 2,
              bridgeKey="mac.memory.history", chartStyle="threshold"),
        panel("mac/procs", "bridge", "Top Processes", 0, 3, 8, 1,
              bridgeKey="demo.processes"),
    ]
    return board("Mac Vitals", 8, 4, "terminal", "grid", ps, spacing=10)


def world_board():
    zones = [
        ("Cupertino", "America/Los_Angeles"),
        ("New York", "America/New_York"),
        ("London", "Europe/London"),
        ("Berlin", "Europe/Berlin"),
        ("Tokyo", "Asia/Tokyo"),
        ("Sydney", "Australia/Sydney"),
    ]
    ps = []
    for i, (city, tz) in enumerate(zones):
        ps.append(panel(f"world/{tz}", "clock", city,
                        (i % 3) * 2, (i // 3), 2, 1,
                        timeZoneID=tz, showsSeconds=False, showsClockDate=False))
    ps.append(panel("world/news", "bridge", "Headlines", 6, 0, 2, 2,
                    bridgeKey="demo.headlines"))
    ps.append(panel("world/note", "text", "About", 0, 2, 8, 2,
                    text=("One board per part of your life. Switch between them in the "
                          "sidebar, pin a different one to each screen, and every device "
                          "you own stays in step over iCloud.")))
    return board("World Clocks", 8, 4, "blueprint", "topography", ps, spacing=12)


def theme_board():
    """A tile per theme, so one screenshot shows the whole palette set."""
    themes = [
        ("board", "Status Board"), ("glass", "Glass"), ("carbon", "Carbon"),
        ("slate", "Slate"), ("paper", "Paper"), ("terminal", "Terminal"),
        ("blueprint", "Blueprint"), ("sunset", "Sunset"), ("aurora", "Aurora"),
    ]
    blurb = {
        "board": "The original. Dark felt, bright numbers.",
        "glass": "Frosted panels over whatever is behind them.",
        "carbon": "Near-black, high contrast, no colour cast.",
        "slate": "Cool grey. Quiet enough for a wall all day.",
        "paper": "The light one. Reads in a sunlit kitchen.",
        "terminal": "Green on black, for the machine room.",
        "blueprint": "Drafting blue with a fine grid.",
        "sunset": "Warm ambers over a deep horizon.",
        "aurora": "Cold greens and violets in motion.",
    }
    ps = []
    for i, (raw, label) in enumerate(themes):
        ps.append(panel(f"theme/{raw}", "text", label,
                        (i % 3) * 2, (i // 3), 2, 1,
                        text=blurb[raw],
                        appearance=appearance(theme=raw, cornerRadius=16)))
    ps.append(panel("theme/note", "text", "Themes", 6, 0, 2, 3,
                    text=("Nine themes ship built in. A theme sets the whole board — "
                          "background, panel fill, border, type colour — and any single "
                          "panel can override it. Add a wallpaper and a scrim underneath "
                          "and the same layout reads completely differently.")))
    return board("Themes", 8, 3, "carbon", "none", ps, spacing=14)


def glass_board():
    """The appearance showcase: one wallpaper cut across masked panels."""
    def glass(**kw):
        return appearance(theme="glass", backgroundStyle="clear", material="thin",
                          borderWidth=0, cornerRadius=18, **kw)

    def masked(**kw):
        base = {"scrim": 0.35}
        base.update(kw)
        return appearance(theme="glass", backgroundStyle="boardBackdrop",
                          borderWidth=0, cornerRadius=18, **base)

    ps = [
        panel("glass/weather", "weather", "Weather", 0, 0, 4, 2,
              latitude=37.7749, longitude=-122.4194, locationName="San Francisco",
              appearance=appearance(theme="glass", backgroundStyle="clear",
                                    borderWidth=0, cornerRadius=18,
                                    dynamic="weather", hidesTitleBar=True)),
        panel("glass/clock", "clock", "Clock", 4, 0, 2, 1,
              showsSeconds=False, appearance=masked()),
        panel("glass/countdown", "countdown", "Launch", 6, 0, 2, 1,
              targetDate=iso(NOW + timedelta(days=30)), appearance=masked()),
        panel("glass/cpu", "progress", "CPU", 4, 1, 2, 1,
              bridgeKey="mac.cpu", progressFormat="circle", appearance=glass()),
        panel("glass/mem", "progress", "Memory", 6, 1, 2, 1,
              bridgeKey="mac.memory", progressFormat="gradient", appearance=glass()),
        panel("glass/graph", "graph", "Mac CPU", 0, 2, 5, 2,
              bridgeKey="mac.cpu.history", chartStyle="area",
              appearance=masked(scrim=0.45)),
        panel("glass/about", "text", "About", 5, 2, 3, 2,
              text=("Every panel here is see-through. The three across the middle each "
                    "show their own slice of the same wallpaper — move one and it "
                    "re-cuts. Board Appearance changes the picture behind all of them."),
              appearance=glass(scrim=0.25)),
    ]
    return board("Glass", 8, 4, "glass", "aurora", ps, spacing=16)


BOARDS = [home_board, family_board, vitals_board, glass_board, world_board, theme_board]


# --------------------------------------------------------------------------
# snapshots
# --------------------------------------------------------------------------

def rec(case, payload):
    return {"snapshot": {case: payload}, "updatedAt": iso(NOW)}


def series(values, unit=None, step_s=30):
    pts = [{"date": iso(NOW - timedelta(seconds=step_s * (len(values) - 1 - i))),
            "value": v} for i, v in enumerate(values)]
    body = {"points": pts}
    if unit:
        body["unit"] = unit
    return rec("series", {"_0": body})


def wave(n, lo, hi, periods=3.0, phase=0.0):
    """A deterministic wobble — no RNG, so a reseed is byte-identical."""
    out = []
    for i in range(n):
        t = i / (n - 1)
        a = math.sin(t * math.pi * 2 * periods + phase)
        b = math.sin(t * math.pi * 2 * periods * 2.7 + phase * 1.7) * 0.35
        out.append(round(lo + (hi - lo) * ((a + b) / 2.7 + 1) / 2, 1))
    return out


def snapshots():
    s = {}

    # Mac vitals over the bridge.
    s["bridge/mac.cpu"] = rec("number", {"_0": 34.8, "unit": "%"})
    s["bridge/mac.memory"] = rec("number", {"_0": 61.2, "unit": "%"})
    s["bridge/mac.disk"] = rec("number", {"_0": 68.6, "unit": "%"})
    s["bridge/mac.net.in"] = rec("number", {"_0": 42.0, "unit": "%"})
    s["bridge/mac.cpu.history"] = series(wave(60, 12, 92), "%")
    s["bridge/mac.memory.history"] = series(wave(60, 48, 74, periods=1.6, phase=1.1), "%")
    s["bridge/mac.net.in.history"] = series(wave(60, 2, 88, periods=5.0, phase=0.4), "%")
    s["bridge/mac.uptime"] = rec("text", {"_0": "6d 4h"})

    # House.
    s["bridge/demo.thermostat"] = rec("thermostat", {"_0": {
        "id": "demo-thermostat",
        "name": "Hallway",
        "room": "Hallway",
        "currentC": 21.7,
        "humidity": 44,
        "targetC": 21.1,
        "mode": "cool",
        "status": "cooling",
        "fanIsOn": True,
        "isOnline": True,
        "outdoorC": 28.3,
        "sourceLabel": "HomeKit",
        "updatedAt": iso(NOW - timedelta(minutes=2)),
        "samples": [],
        "rooms": [],
    }})

    def reading(rid, name, room, kind, **kw):
        base = {"id": rid, "name": name, "room": room, "kind": kind,
                "isReachable": True, "batteryIsLow": False,
                "updatedAt": iso(NOW - timedelta(minutes=3))}
        base.update(kw)
        return base

    s["bridge/demo.rooms"] = rec("homeSensors", {"_0": {
        "homeName": "Home",
        "sourceLabel": "HomeKit",
        "readings": [
            reading("r1", "Kitchen", "Kitchen", "temperature", value=22.4),
            reading("r2", "Living Room", "Living Room", "temperature", value=21.9),
            reading("r3", "Bedroom", "Bedroom", "temperature", value=20.6),
            reading("r4", "Office", "Office", "temperature", value=23.1),
        ],
    }})

    s["bridge/demo.contacts"] = rec("homeSensors", {"_0": {
        "homeName": "Home",
        "sourceLabel": "HomeKit",
        "readings": [
            reading("c1", "Front Door", "Entry", "lock", isActive=False, text="Locked"),
            reading("c2", "Back Door", "Kitchen", "contact", isActive=False, text="Closed"),
            reading("c3", "Garage", "Garage", "contact", isActive=True, text="Open"),
            reading("c4", "Kitchen Window", "Kitchen", "contact", isActive=False, text="Closed"),
            reading("c5", "Hallway", "Hallway", "motion", isActive=True, text="Motion"),
            reading("c6", "Basement", "Basement", "leak", isActive=False, text="Dry"),
        ],
    }})

    # School.
    s["bridge/demo.grades"] = rec("grades", {"_0": [
        {"id": "g1", "course": "Algebra II", "score": 94.2, "letter": "A",
         "teacher": "Ms. Alvarez", "ungradedCount": 1},
        {"id": "g2", "course": "Biology", "score": 88.5, "letter": "B+",
         "teacher": "Mr. Okonkwo", "ungradedCount": 0},
        {"id": "g3", "course": "World History", "score": 91.0, "letter": "A-",
         "teacher": "Ms. Bright", "ungradedCount": 2},
        {"id": "g4", "course": "English 10", "score": 79.4, "letter": "C+",
         "teacher": "Mr. Delacroix", "ungradedCount": 0},
        {"id": "g5", "course": "Spanish II", "score": 96.8, "letter": "A",
         "teacher": "Sra. Peña", "ungradedCount": 0},
    ]})

    def klass(kid, course, hhmm, teacher, mins=50, required=True):
        start = NOW.astimezone(timezone(timedelta(hours=-7))).replace(
            hour=int(hhmm[:2]), minute=int(hhmm[3:]), second=0, microsecond=0)
        end = start + timedelta(minutes=mins)
        label = start.strftime("%-I:%M %p")
        return {"id": kid, "course": course, "start": iso(start), "end": iso(end),
                "timeText": label, "teacher": teacher, "attendanceRequired": required}

    s["bridge/demo.schedule"] = rec("schedule", {"_0": [
        klass("s1", "Algebra II", "08:30", "Ms. Alvarez"),
        klass("s2", "Biology", "09:30", "Mr. Okonkwo"),
        klass("s3", "World History", "11:00", "Ms. Bright"),
        klass("s4", "English 10", "13:00", "Mr. Delacroix", required=False),
        klass("s5", "Spanish II", "14:15", "Sra. Peña"),
    ]})

    def item(aid, title, course, state, days, score=None, points=None):
        d = {"id": aid, "title": title, "course": course, "state": state,
             "due": iso(NOW + timedelta(days=days))}
        if score is not None:
            d["score"] = score
        if points is not None:
            d["pointsPossible"] = points
        return d

    s["bridge/demo.assignments"] = rec("assignments", {"_0": {
        "due": [
            item("a1", "Ch. 7 Problem Set", "Algebra II", "dueToday", 0),
            item("a2", "Cell Division Lab Report", "Biology", "dueToday", 0),
        ],
        "late": [
            item("a3", "Essay: The Silk Road", "World History", "late", -2),
        ],
        "redo": [
            item("a4", "Vocabulary Quiz 4", "Spanish II", "redo", -5, score=14, points=20),
        ],
        "awaitingGrading": 3,
    }})

    # Odds and ends.
    s["bridge/demo.processes"] = rec("table", {"_0": {
        "columns": ["Process", "CPU", "Memory", "State"],
        "rows": [
            ["Xcode", "38.2%", "4.1 GB", "OK"],
            ["WindowServer", "11.4%", "820 MB", "OK"],
            ["swift-frontend", "9.8%", "1.6 GB", "OK"],
            ["Safari", "4.1%", "1.2 GB", "OK"],
            ["StatusBoard", "0.6%", "148 MB", "OK"],
        ],
    }})

    s["bridge/demo.headlines"] = rec("feed", {"_0": [
        {"id": "h1", "title": "Pacific storm sets up a wet weekend",
         "sourceName": "Weather", "published": iso(NOW - timedelta(minutes=18))},
        {"id": "h2", "title": "Transit board approves late-night service",
         "sourceName": "City", "published": iso(NOW - timedelta(hours=1))},
        {"id": "h3", "title": "Two new bike lanes open downtown",
         "sourceName": "City", "published": iso(NOW - timedelta(hours=3))},
        {"id": "h4", "title": "Library extends Sunday hours",
         "sourceName": "City", "published": iso(NOW - timedelta(hours=6))},
    ]})

    return s


# --------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if "--list" in args:
        for fn in BOARDS:
            print(fn().get("name"))
        return 0
    if not args:
        print(__doc__)
        return 2

    first = None
    if "--first" in args:
        i = args.index("--first")
        first = args[i + 1]
        args = args[:i] + args[i + 2:]

    target = args[0]
    os.makedirs(target, exist_ok=True)

    boards = [fn() for fn in BOARDS]

    # DashboardStore.load() selects dashboards.first, so putting a board at the
    # front is all it takes to launch straight into it — no tapping through the
    # sidebar on five platforms to photograph six boards.
    if first:
        match = [b for b in boards if b["name"].lower() == first.lower()]
        if not match:
            print(f"no board named {first!r}; have: "
                  + ", ".join(b["name"] for b in boards), file=sys.stderr)
            return 2
        boards = match + [b for b in boards if b is not match[0]]
    with open(os.path.join(target, "dashboards.json"), "w") as fh:
        json.dump(boards, fh, indent=1, sort_keys=True)
    with open(os.path.join(target, "snapshots.json"), "w") as fh:
        json.dump(snapshots(), fh, indent=1, sort_keys=True)

    # tvOS and watchOS can't author boards, so DashboardStore.load() treats
    # dashboards.json as nothing but a cache of iCloud and drops every board
    # that isn't listed here. Without this the TV launches to an empty shelf.
    with open(os.path.join(target, "icloud-boards.json"), "w") as fh:
        json.dump([b["id"] for b in boards], fh, indent=1)

    print(f"seeded {len(boards)} boards and {len(snapshots())} snapshots -> {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
