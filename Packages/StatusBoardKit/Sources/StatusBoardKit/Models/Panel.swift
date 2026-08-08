import Foundation

public enum PanelKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case clock
    case weather
    case graph
    case progress
    case feed
    case calendar
    case webClip
    case image
    case text
    case countdown
    case table
    case status
    case mcp
    case bridge
    case github
    case appStoreConnect
    case supabase
    case logs
    case health
    case canvas
    case k12schedule
    case grades
    case schedule
    case assignments
    case tessie
    case homeKit
    case homeAssistant
    case nest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clock: return "Clock"
        case .weather: return "Weather"
        case .graph: return "Graph"
        case .progress: return "Progress"
        case .feed: return "RSS Feed"
        case .calendar: return "Calendar"
        case .webClip: return "Web Clip"
        case .image: return "Image"
        case .text: return "Text"
        case .countdown: return "Countdown"
        case .table: return "Table"
        case .status: return "Service Status"
        case .mcp: return "MCP Tool"
        case .bridge: return "Bridge Value"
        case .github: return "GitHub"
        case .appStoreConnect: return "App Store Connect"
        case .supabase: return "Supabase"
        case .logs: return "Web Logs"
        case .health: return "Health"
        case .canvas: return "Canvas"
        case .k12schedule: return "K12 Class Schedule"
        case .grades: return "Grades"
        case .schedule: return "Schedule"
        case .assignments: return "Assignments"
        case .tessie: return "Tesla (Tessie)"
        case .homeKit: return "Home (HomeKit)"
        case .homeAssistant: return "Home Assistant"
        case .nest: return "Nest Thermostat"
        }
    }

    public var symbolName: String {
        switch self {
        case .clock: return "clock"
        case .weather: return "cloud.sun"
        case .graph: return "chart.xyaxis.line"
        case .progress: return "circle.dotted.circle"
        case .feed: return "dot.radiowaves.up.forward"
        case .calendar: return "calendar"
        case .webClip: return "safari"
        case .image: return "photo"
        case .text: return "text.alignleft"
        case .countdown: return "timer"
        case .table: return "tablecells"
        case .status: return "checkmark.seal"
        case .mcp: return "wand.and.stars"
        case .bridge: return "antenna.radiowaves.left.and.right"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .appStoreConnect: return "app.badge"
        case .supabase: return "cylinder.split.1x2"
        case .logs: return "doc.text.magnifyingglass"
        case .health: return "heart.fill"
        case .canvas: return "graduationcap.fill"
        case .k12schedule: return "clock.badge.checkmark"
        case .grades: return "chart.bar.doc.horizontal"
        case .schedule: return "calendar.day.timeline.left"
        case .assignments: return "checklist"
        case .tessie: return "car.side.fill"
        case .homeKit: return "house.fill"
        case .homeAssistant: return "house.and.flag.fill"
        case .nest: return "thermometer.and.liquid.waves"
        }
    }

    public var defaultSize: (width: Int, height: Int) {
        switch self {
        case .clock, .countdown, .progress: return (2, 1)
        case .weather: return (3, 1)
        case .graph, .feed, .table, .webClip, .calendar, .image: return (4, 2)
        case .github, .appStoreConnect, .supabase, .logs, .canvas: return (4, 2)
        case .k12schedule: return (3, 2)
        case .grades, .schedule, .assignments: return (4, 2)
        case .tessie: return (4, 3)
        case .homeKit, .homeAssistant, .nest: return (3, 2)
        case .health: return (2, 1)
        case .text, .status, .mcp, .bridge: return (2, 1)
        }
    }


    /// Whether the panel's content comes from a periodic fetch task.
    public var isFetched: Bool {
        switch self {
        case .weather, .graph, .progress, .feed, .calendar, .table,
             .status, .mcp, .webClip, .image,
             .github, .appStoreConnect, .supabase, .logs, .health, .canvas,
             .k12schedule, .grades, .schedule, .assignments, .tessie,
             .homeKit, .homeAssistant, .nest:
            return true
        case .clock, .countdown, .text, .bridge:
            return false
        }
    }

    /// A car's state changes by the minute while it is moving, so five is far
    /// too coarse. Tessie answers from its own cache, so this doesn't keep the
    /// vehicle awake.
    public var defaultRefreshSeconds: Double {
        switch self {
        case .tessie: return 60
        // The house changes by the minute, and short-cycling detection is
        // only as sharp as the sample rate: at five minutes a four-minute
        // compressor run is invisible. HomeKit reads come off the local
        // network and Home Assistant off your own server, so a minute costs
        // nothing. Nest is a metered Google API with a per-structure quota,
        // hence the slower default.
        case .homeKit, .homeAssistant: return 60
        case .nest: return 180
        default: return 300
        }
    }

    /// Which of the three home services this panel talks to, if any.
    public var homeProvider: HomeProvider? {
        switch self {
        case .homeKit: return .homeKit
        case .homeAssistant: return .homeAssistant
        case .nest: return .nest
        default: return nil
        }
    }

    /// Whether the panel authenticates against Canvas / Instructure with the
    /// shared address and access token. See `CanvasCredentials`.
    public var usesCanvasCredentials: Bool {
        switch self {
        case .canvas, .grades, .assignments: return true
        default: return false
        }
    }

    /// Whether the panel authenticates against Tessie with the shared API key.
    /// See `TessieCredentials`.
    public var usesTessieCredentials: Bool { self == .tessie }
}

public struct Panel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Shared content identity for a panel intentionally placed on more than
    /// one dashboard. Each placement keeps its own `id` and `frame`, while the
    /// title, kind, settings, fetched snapshot, and WidgetKit data stay linked.
    /// Nil means this is an independent panel (the backward-compatible default).
    public var linkedContentID: UUID?
    /// Revision used to converge linked content when its dashboard records
    /// arrive from CloudKit in a different order. Layout is intentionally not
    /// part of this revision because every placement owns its own frame.
    public var linkedContentModifiedAt: Date?
    public var kind: PanelKind
    public var title: String
    public var frame: GridRect
    public var settings: PanelSettings

    public init(id: UUID = UUID(), linkedContentID: UUID? = nil,
                linkedContentModifiedAt: Date? = nil,
                kind: PanelKind, title: String, frame: GridRect,
                settings: PanelSettings = PanelSettings()) {
        self.id = id
        self.linkedContentID = linkedContentID
        self.linkedContentModifiedAt = linkedContentModifiedAt
        self.kind = kind
        self.title = title
        self.frame = frame
        self.settings = settings
    }

    /// The key this panel's data lives under in the snapshot store.
    public var snapshotKey: String {
        if kind == .bridge || ((kind == .graph || kind == .progress) && settings.url == nil) {
            if let key = settings.bridgeKey, !key.isEmpty {
                return BridgeKeys.prefixed(key)
            }
        }
        return (linkedContentID ?? id).uuidString
    }

    /// True when edits to this panel's content are replicated to another
    /// dashboard placement. Layout remains local to each dashboard/device.
    public var isSharedAcrossDashboards: Bool { linkedContentID != nil }

    /// Whether this panel's latest rendered value follows the board through the
    /// user's private CloudKit database. Calendar and HomeKit default on because
    /// some Apple platforms cannot read those frameworks; Health defaults off
    /// and requires an explicit privacy choice.
    public var sharesLatestSnapshotViaICloud: Bool {
        // Camera pixels are never portable, even if this panel used to be a
        // sensor with an explicit opt-in before its mode was changed.
        if kind == .homeKit && settings.homeMode == .camera { return false }
        return settings.syncSnapshotToICloud ?? (kind == .calendar || kind == .homeKit)
    }
}

/// The full chart-style family, inspired by TerminalWidget's renderer set.
public enum ChartStyle: String, Codable, CaseIterable, Sendable {
    case line
    case smooth
    case area
    case bar
    case lollipop
    case strip
    case delta
    case threshold
    case peak
    case radial
    case waveform
    case matrix

    public var displayName: String {
        switch self {
        case .line: return "Line"
        case .smooth: return "Smooth"
        case .area: return "Area"
        case .bar: return "Bars"
        case .lollipop: return "Lollipop"
        case .strip: return "Strip"
        case .delta: return "Delta"
        case .threshold: return "Threshold"
        case .peak: return "Peak"
        case .radial: return "Radial"
        case .waveform: return "Waveform"
        case .matrix: return "Matrix"
        }
    }
}

/// Progress renderings, after TerminalWidget's progress formats.
public enum ProgressFormat: String, Codable, CaseIterable, Sendable {
    case bar
    case circle
    case watch
    case dots
    case stack
    case matrix
    case gradient

    public var displayName: String { rawValue.capitalized }
}

/// Metrics the Health panel can display (HealthKit; iPhone/iPad/Watch).
public enum HealthMetric: String, Codable, CaseIterable, Sendable {
    case steps
    case activeEnergy
    case exerciseMinutes
    case heartRate
    case sleepHours

    public var displayName: String {
        switch self {
        case .steps: return "Steps Today"
        case .activeEnergy: return "Active Energy"
        case .exerciseMinutes: return "Exercise Minutes"
        case .heartRate: return "Latest Heart Rate"
        case .sleepHours: return "Sleep (last night)"
        }
    }

    public var unit: String {
        switch self {
        case .steps: return "steps"
        case .activeEnergy: return "kcal"
        case .exerciseMinutes: return "min"
        case .heartRate: return "bpm"
        case .sleepHours: return "h"
        }
    }
}

/// One RSS/Atom feed inside a news panel. A panel may merge several, in which
/// case their items are interleaved newest-first.
public struct FeedSource: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Optional label shown beside this feed's items. Empty means "use the
    /// name the feed gives itself", falling back to its host.
    public var name: String
    public var url: String
    /// Off keeps the feed configured but out of the merge — handy for muting
    /// a noisy source without losing its URL.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String = "", url: String = "", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
    }

    public var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How list-like panels (feed, calendar) present items.
public enum ListDisplayMode: String, Codable, CaseIterable, Sendable {
    case list
    case ticker

    public var displayName: String { rawValue.capitalized }
}

/// Flat, optional-heavy settings bag. Each panel kind reads the fields it
/// cares about. Decoding uses `decodeIfPresent` throughout so dashboards
/// saved by older builds (or synced from other devices) always load.
public struct PanelSettings: Codable, Hashable, Sendable {
    /// Seconds between refreshes for fetched panels.
    public var refreshSeconds: Double = 300

    // Web query / feed / table / web clip / image
    public var url: String?
    /// Dot path into fetched JSON for a single value, e.g. "data.stats.count".
    public var valuePath: String?
    /// Dot path resolving to an array for series/table data, e.g. "data.items[*]".
    public var seriesPath: String?
    /// Path within each series element for the numeric value.
    public var pointValuePath: String?
    /// Path within each series element for the label.
    public var pointLabelPath: String?
    public var unit: String?
    public var chartStyle: ChartStyle = .line
    /// Chart baseline (defaults to the data minimum when nil).
    public var chartBase: Double?

    // Progress
    public var progressFormat: ProgressFormat = .bar
    /// Treat this as the 100% value when the source reports raw numbers.
    public var progressTotal: Double?

    // Web clip
    /// Rendered page zoom for web clips.
    public var webClipZoom: Double = 1.0
    /// CSS selector of the element to isolate ("show only this region").
    public var webClipSelector: String?
    /// CSS selectors of elements to hide (1Blocker-style).
    public var webClipHideSelectors: [String] = []
    /// Block ads and trackers inside the clip (EasyList-based).
    public var webClipBlocksAds: Bool = true
    /// Sign in automatically using credentials saved in the Keychain for this
    /// page's host. The credentials themselves are never stored here.
    public var webClipAutoLogin: Bool = false

    // Image
    /// Core Image filter chain, e.g. "sepia:70,blur:20" — see SBImageFilter.
    public var imageFilter: String?

    // Clock
    public var timeZoneID: String?
    public var showsSeconds: Bool = true
    /// Which face the clock draws. Defaults to the classic LCD, so every clock
    /// saved before faces existed keeps the look it had.
    public var clockStyle: ClockStyle = .lcd
    public var clockHourFormat: ClockHourFormat = .automatic
    /// The date line under the time. Off suits a small panel or a face that is
    /// already busy.
    public var showsClockDate: Bool = true
    /// Draw the sun's position and the night wedge on faces that can use them.
    /// The coordinates come from the shared `latitude` / `longitude` fields, so
    /// a clock and a weather panel pick their place the same way.
    public var showsSunPosition: Bool = true
    /// Traditional hour/minute hands over the Solar Dial. Its second hand is
    /// controlled by `showsSeconds`, just like the analog face.
    public var showsClockHands: Bool = false

    // Weather
    /// Resolved coordinates. Always filled in for a working panel, whatever
    /// way the location was chosen — a place search, a station lookup and
    /// Current Location all write their answer back here, so a panel keeps
    /// showing weather even when the network or the device's location is
    /// unavailable on a later refresh.
    public var latitude: Double?
    public var longitude: Double?
    public var locationName: String?
    /// How the location above was chosen.
    public var weatherLocationMode: WeatherLocationMode = .current
    /// A city, postal code or street address, for `.place`.
    public var weatherPlaceQuery: String?
    /// Observation station identifier, for `.station` (e.g. "KSFO").
    public var weatherStationID: String?
    public var weatherStationNetwork: WeatherStationNetwork = .nws
    /// Base URL of a personal weather station's JSON endpoint, for `.personal`.
    public var weatherPersonalURL: String?
    public var weatherPersonalFormat: PersonalWeatherFormat = .automatic
    /// Dot paths into a custom PWS payload, keyed by `PersonalWeatherField`.
    public var weatherPersonalPaths: [String: String] = [:]
    public var weatherUnits: WeatherUnits = .automatic
    public var weatherForecastLayout: WeatherForecastLayout = .automatic

    // Calendar
    public var calendarDaysAhead: Int = 7
    /// Empty means all calendars. Names accompany EventKit identifiers so a
    /// selection can be matched after syncing to a different device, where
    /// identifiers are not guaranteed to be identical.
    public var calendarIdentifiers: Set<String> = []
    public var calendarNames: Set<String> = []

    // Health
    public var healthMetric: HealthMetric = .steps

    /// Friendlier names for classes, keyed by the school's course name.
    /// "AP US History A (Sem 1)" → "History".
    public var courseAliases: [String: String] = [:]

    /// Courses the user has unchecked, keyed by the school's course name.
    /// Schools enroll students in shells like "Counselor" or "INDLS" that carry
    /// no real grade, and they'd otherwise sit at the top of the panel as a
    /// permanent "—". Hiding is a display choice, so the fetched data keeps
    /// them and the editor can still list them to be brought back.
    public var hiddenCourses: Set<String> = []

    /// The grades a panel should actually draw, in the order given.
    public func visibleGrades(_ grades: [CourseGrade]) -> [CourseGrade] {
        guard !hiddenCourses.isEmpty else { return grades }
        return grades.filter { !hiddenCourses.contains($0.course) }
    }

    // Tessie (Tesla)
    /// What the panel shows while the car is parked, in order. The first
    /// field with data becomes the headline; the rest become tiles.
    public var tessieParkedFields: [TessieField] = TessieField.defaultParked
    /// The same, for while it is driving.
    public var tessieDrivingFields: [TessieField] = TessieField.defaultDriving
    /// Swap layouts on their own as the car's gear changes.
    public var tessieAutoContext: Bool = true
    /// Which layout to show when `tessieAutoContext` is off — and, when it is
    /// on, which one to fall back to before any data has arrived.
    public var tessieContext: TessieContext = .parked

    // Home (HomeKit / Home Assistant / Nest)
    /// Which question the panel answers — rooms, sensors, activity, a
    /// thermostat, its trend, its health, or a camera.
    public var homeMode: HomePanelMode = .rooms
    /// The HomeKit home to read, when the Apple ID has more than one. Nil
    /// means the primary home. Unused by the other two providers.
    public var homeName: String?
    /// The one accessory a thermostat or camera panel is pinned to: a
    /// HomeKit service identifier, a Home Assistant entity id, or a Nest
    /// device resource name. Nil means "the first one found", so a panel
    /// works before anything is chosen.
    public var homeTarget: String?
    /// Rooms to include. Empty means all of them.
    public var homeRooms: [String] = []
    /// Which kinds of reading a sensor panel shows. Empty falls back to the
    /// sensible set for the mode.
    public var homeSensorKinds: [HomeSensorKind] = []
    /// How far back the trend chart and the equipment analysis look.
    public var hvacTrendHours: Double = 12
    /// Show the equipment-health line under a thermostat panel.
    public var showsHVACDiagnostics: Bool = true
    /// Draw the room's other temperatures under a thermostat.
    public var showsHomeRoomStrip: Bool = true

    /// The reading kinds this panel actually draws — an explicit choice, or
    /// whatever the mode implies.
    public var resolvedSensorKinds: [HomeSensorKind] {
        if !homeSensorKinds.isEmpty { return homeSensorKinds }
        switch homeMode {
        case .activity: return HomeSensorKind.activitySelection
        case .rooms: return [.temperature, .humidity]
        default: return HomeSensorKind.defaultSelection
        }
    }

    /// Clamped so a stray value can't ask the analyzer for a year of history
    /// or a chart with two points in it.
    public var resolvedTrendHours: Double {
        min(168, max(1, hvacTrendHours))
    }

    // Feed / calendar presentation
    public var listDisplay: ListDisplayMode = .list

    // Feed
    /// Every feed the panel merges. Empty on panels saved before multi-feed
    /// support — `activeFeedSources` falls back to the legacy single `url`.
    public var feedSources: [FeedSource] = []
    /// Show each item's site favicon so merged sources stay distinguishable.
    public var feedShowsSourceIcons: Bool = true
    /// Show the source's name under each headline. Off by default on a single
    /// feed, where every row would repeat the same word.
    public var feedShowsSourceNames: Bool = true

    /// The feeds a news panel should actually fetch, oldest settings included:
    /// a panel saved before multi-feed support carries one URL in `url`.
    public var activeFeedSources: [FeedSource] {
        let configured = feedSources.filter { $0.isEnabled && !$0.trimmedURL.isEmpty }
        if !configured.isEmpty { return configured }
        let legacy = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return [] }
        return [FeedSource(url: legacy)]
    }

    /// Moves a legacy single-URL feed panel into `feedSources` so the editor
    /// has a row to show. Safe to call repeatedly.
    public mutating func migrateFeedSourcesIfNeeded() {
        guard feedSources.isEmpty else { return }
        let legacy = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return }
        feedSources = [FeedSource(url: legacy)]
    }

    // Countdown
    public var targetDate: Date?

    // Text
    public var text: String?

    // Table
    public var tableHasHeader: Bool = true
    public var tableZebra: Bool = true
    public var tableStatusColoring: Bool = true

    // Status
    public var statusTargets: [StatusTarget] = []

    // Bridge
    public var bridgeKey: String?

    // MCP
    public var mcp: MCPPanelConfig?

    // External connectors (GitHub, App Store Connect, Supabase, logs)
    public var connector: ConnectorConfig?

    // Appearance
    /// Per-panel accent override as "#RRGGBB"; nil uses the theme amber.
    public var accentColorHex: String?
    /// Theme, background, transparency, blur and dynamic-styling options.
    public var appearance = PanelAppearance()

    // Alerts — local notification when the panel's value crosses a limit.
    public var alertAbove: Double?
    public var alertBelow: Double?

    /// Explicit override for cross-device snapshot sync. Nil uses the safe
    /// per-kind default described by `Panel.sharesLatestSnapshotViaICloud`.
    public var syncSnapshotToICloud: Bool?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case refreshSeconds, url, valuePath, seriesPath, pointValuePath, pointLabelPath
        case unit, chartStyle, chartBase
        case progressFormat, progressTotal
        case webClipZoom, webClipSelector, webClipHideSelectors, webClipBlocksAds
        case webClipAutoLogin
        case imageFilter
        case timeZoneID, showsSeconds, clockStyle, clockHourFormat
        case showsClockDate, showsSunPosition, showsClockHands
        case latitude, longitude, locationName
        case calendarDaysAhead, calendarIdentifiers, calendarNames
        case listDisplay, healthMetric, courseAliases, hiddenCourses
        case feedSources, feedShowsSourceIcons, feedShowsSourceNames
        case tessieParkedFields, tessieDrivingFields, tessieAutoContext, tessieContext
        case homeMode, homeName, homeTarget, homeRooms, homeSensorKinds
        case hvacTrendHours, showsHVACDiagnostics, showsHomeRoomStrip
        case targetDate, text
        case tableHasHeader, tableZebra, tableStatusColoring
        case statusTargets, bridgeKey, mcp, connector
        case accentColorHex, appearance, alertAbove, alertBelow, syncSnapshotToICloud
        case weatherLocationMode, weatherPlaceQuery, weatherStationID
        case weatherStationNetwork, weatherPersonalURL, weatherPersonalFormat
        case weatherPersonalPaths, weatherUnits, weatherForecastLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = try container.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 300
        url = try container.decodeIfPresent(String.self, forKey: .url)
        valuePath = try container.decodeIfPresent(String.self, forKey: .valuePath)
        seriesPath = try container.decodeIfPresent(String.self, forKey: .seriesPath)
        pointValuePath = try container.decodeIfPresent(String.self, forKey: .pointValuePath)
        pointLabelPath = try container.decodeIfPresent(String.self, forKey: .pointLabelPath)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        chartStyle = (try? container.decodeIfPresent(ChartStyle.self, forKey: .chartStyle)) ?? .line
        chartBase = try container.decodeIfPresent(Double.self, forKey: .chartBase)
        progressFormat = (try? container.decodeIfPresent(ProgressFormat.self, forKey: .progressFormat)) ?? .bar
        progressTotal = try container.decodeIfPresent(Double.self, forKey: .progressTotal)
        webClipZoom = try container.decodeIfPresent(Double.self, forKey: .webClipZoom) ?? 1.0
        webClipSelector = try container.decodeIfPresent(String.self, forKey: .webClipSelector)
        webClipHideSelectors = try container.decodeIfPresent([String].self, forKey: .webClipHideSelectors) ?? []
        webClipBlocksAds = try container.decodeIfPresent(Bool.self, forKey: .webClipBlocksAds) ?? true
        webClipAutoLogin = try container.decodeIfPresent(Bool.self, forKey: .webClipAutoLogin) ?? false
        imageFilter = try container.decodeIfPresent(String.self, forKey: .imageFilter)
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID)
        showsSeconds = try container.decodeIfPresent(Bool.self, forKey: .showsSeconds) ?? true
        // A face this build doesn't know falls back to the LCD rather than
        // failing the whole panel — same rule as every other enum here.
        clockStyle = (try? container.decodeIfPresent(ClockStyle.self, forKey: .clockStyle))
            .flatMap { $0 } ?? .lcd
        // A panel saved before faces existed was drawn as "HH:mm" whatever the
        // region said, so that is what it decodes to — a clock that has been
        // reading 13:42 for a year must not quietly become 1:42 PM. New panels
        // start on `.automatic` instead, from the property's own default.
        clockHourFormat = (try? container.decodeIfPresent(ClockHourFormat.self,
                                                          forKey: .clockHourFormat))
            .flatMap { $0 } ?? .twentyFour
        showsClockDate = try container.decodeIfPresent(Bool.self, forKey: .showsClockDate) ?? true
        showsSunPosition = try container.decodeIfPresent(Bool.self, forKey: .showsSunPosition) ?? true
        showsClockHands = try container.decodeIfPresent(Bool.self, forKey: .showsClockHands) ?? false
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        locationName = try container.decodeIfPresent(String.self, forKey: .locationName)
        calendarDaysAhead = try container.decodeIfPresent(Int.self, forKey: .calendarDaysAhead) ?? 7
        calendarIdentifiers = try container.decodeIfPresent(Set<String>.self,
                                                             forKey: .calendarIdentifiers) ?? []
        calendarNames = try container.decodeIfPresent(Set<String>.self,
                                                       forKey: .calendarNames) ?? []
        healthMetric = (try? container.decodeIfPresent(HealthMetric.self, forKey: .healthMetric)) ?? .steps
        courseAliases = try container.decodeIfPresent([String: String].self, forKey: .courseAliases) ?? [:]
        hiddenCourses = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenCourses) ?? []
        // Decoded through raw strings so a field this build doesn't know is
        // dropped on its own, keeping the rest of the user's choices. As
        // `[TessieField]`, one unrecognised name would throw away the whole
        // list and silently reset the panel to defaults.
        tessieParkedFields = try container.decodeIfPresent([String].self, forKey: .tessieParkedFields)
            .map { $0.compactMap(TessieField.init(rawValue:)) } ?? TessieField.defaultParked
        tessieDrivingFields = try container.decodeIfPresent([String].self, forKey: .tessieDrivingFields)
            .map { $0.compactMap(TessieField.init(rawValue:)) } ?? TessieField.defaultDriving
        tessieAutoContext = try container.decodeIfPresent(Bool.self, forKey: .tessieAutoContext) ?? true
        tessieContext = (try? container.decodeIfPresent(TessieContext.self, forKey: .tessieContext))
            .flatMap { $0 } ?? .parked
        homeMode = (try? container.decodeIfPresent(HomePanelMode.self, forKey: .homeMode))
            .flatMap { $0 } ?? .rooms
        homeName = try container.decodeIfPresent(String.self, forKey: .homeName)
        homeTarget = try container.decodeIfPresent(String.self, forKey: .homeTarget)
        homeRooms = try container.decodeIfPresent([String].self, forKey: .homeRooms) ?? []
        // Through raw strings for the same reason the Tessie field lists are:
        // a kind this build doesn't know drops out on its own instead of
        // throwing away every other choice the user made.
        homeSensorKinds = try container.decodeIfPresent([String].self, forKey: .homeSensorKinds)
            .map { $0.compactMap(HomeSensorKind.init(rawValue:)) } ?? []
        hvacTrendHours = try container.decodeIfPresent(Double.self, forKey: .hvacTrendHours) ?? 12
        showsHVACDiagnostics = try container.decodeIfPresent(Bool.self,
                                                             forKey: .showsHVACDiagnostics) ?? true
        showsHomeRoomStrip = try container.decodeIfPresent(Bool.self,
                                                           forKey: .showsHomeRoomStrip) ?? true
        listDisplay = (try? container.decodeIfPresent(ListDisplayMode.self, forKey: .listDisplay)) ?? .list
        feedSources = try container.decodeIfPresent([FeedSource].self, forKey: .feedSources) ?? []
        feedShowsSourceIcons = try container.decodeIfPresent(Bool.self, forKey: .feedShowsSourceIcons) ?? true
        feedShowsSourceNames = try container.decodeIfPresent(Bool.self, forKey: .feedShowsSourceNames) ?? true
        targetDate = try container.decodeIfPresent(Date.self, forKey: .targetDate)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        tableHasHeader = try container.decodeIfPresent(Bool.self, forKey: .tableHasHeader) ?? true
        tableZebra = try container.decodeIfPresent(Bool.self, forKey: .tableZebra) ?? true
        tableStatusColoring = try container.decodeIfPresent(Bool.self, forKey: .tableStatusColoring) ?? true
        statusTargets = try container.decodeIfPresent([StatusTarget].self, forKey: .statusTargets) ?? []
        bridgeKey = try container.decodeIfPresent(String.self, forKey: .bridgeKey)
        mcp = try container.decodeIfPresent(MCPPanelConfig.self, forKey: .mcp)
        connector = try container.decodeIfPresent(ConnectorConfig.self, forKey: .connector)
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex)
        appearance = try container.decodeIfPresent(PanelAppearance.self, forKey: .appearance)
            ?? PanelAppearance()
        alertAbove = try container.decodeIfPresent(Double.self, forKey: .alertAbove)
        alertBelow = try container.decodeIfPresent(Double.self, forKey: .alertBelow)
        syncSnapshotToICloud = try container.decodeIfPresent(Bool.self,
                                                             forKey: .syncSnapshotToICloud)
        weatherLocationMode = (try? container.decodeIfPresent(WeatherLocationMode.self,
                                                             forKey: .weatherLocationMode))
            .flatMap { $0 } ?? ((latitude != nil && longitude != nil) ? .coordinates : .current)
        weatherPlaceQuery = try container.decodeIfPresent(String.self, forKey: .weatherPlaceQuery)
        weatherStationID = try container.decodeIfPresent(String.self, forKey: .weatherStationID)
        weatherStationNetwork = (try? container.decodeIfPresent(WeatherStationNetwork.self,
                                                               forKey: .weatherStationNetwork)) ?? .nws
        weatherPersonalURL = try container.decodeIfPresent(String.self, forKey: .weatherPersonalURL)
        weatherPersonalFormat = (try? container.decodeIfPresent(PersonalWeatherFormat.self,
                                                               forKey: .weatherPersonalFormat)) ?? .automatic
        weatherPersonalPaths = try container.decodeIfPresent([String: String].self,
                                                             forKey: .weatherPersonalPaths) ?? [:]
        weatherUnits = (try? container.decodeIfPresent(WeatherUnits.self, forKey: .weatherUnits)) ?? .automatic
        weatherForecastLayout = (try? container.decodeIfPresent(WeatherForecastLayout.self,
                                                                 forKey: .weatherForecastLayout))
            .flatMap { $0 } ?? .automatic
    }
}

public struct StatusTarget: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: String

    public init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

public struct MCPPanelConfig: Codable, Hashable, Sendable {
    public var server: MCPServerConfig
    public var tool: String
    /// JSON object literal passed as the tool's arguments.
    public var argumentsJSON: String?

    public init(server: MCPServerConfig, tool: String, argumentsJSON: String? = nil) {
        self.server = server
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

public struct MCPServerConfig: Codable, Hashable, Sendable {
    public enum Transport: String, Codable, CaseIterable, Sendable {
        case stdio
        case http
    }

    public var transport: Transport
    /// stdio: executable path; http: unused.
    public var command: String?
    public var arguments: [String]
    /// http: server URL.
    public var url: String?
    public var headers: [String: String]

    public init(transport: Transport, command: String? = nil, arguments: [String] = [],
                url: String? = nil, headers: [String: String] = [:]) {
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.headers = headers
    }
}

/// Configuration for external service connectors. Flat and optional-heavy so
/// one type serves every provider; each source reads the fields it needs.
public struct ConnectorConfig: Codable, Hashable, Sendable {
    /// Provider-specific sub-query, e.g. "runs", "issues", "builds", "sql".
    public var mode: String = ""
    /// GitHub "owner/name".
    public var repo: String?
    /// GitHub PAT / Supabase apikey or management token.
    public var token: String?
    /// Free-form query: Supabase select path or SQL, log URL, ASC app id.
    public var query: String?
    /// App Store Connect API key id.
    public var keyID: String?
    /// App Store Connect issuer id.
    public var issuerID: String?
    /// App Store Connect .p8 private key contents (PEM).
    public var privateKeyPEM: String?
    /// Supabase project URL (select) or project ref (sql).
    public var projectURL: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, repo, token, query, keyID, issuerID, privateKeyPEM, projectURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ""
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        keyID = try container.decodeIfPresent(String.self, forKey: .keyID)
        issuerID = try container.decodeIfPresent(String.self, forKey: .issuerID)
        privateKeyPEM = try container.decodeIfPresent(String.self, forKey: .privateKeyPEM)
        projectURL = try container.decodeIfPresent(String.self, forKey: .projectURL)
    }
}

/// Namespacing for snapshot keys fed by the bridge.
public enum BridgeKeys {
    public static let prefix = "bridge/"

    public static func prefixed(_ key: String) -> String {
        key.hasPrefix(prefix) ? key : prefix + key
    }
}
