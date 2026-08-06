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
             .k12schedule, .grades, .schedule, .assignments:
            return true
        case .clock, .countdown, .text, .bridge:
            return false
        }
    }
}

public struct Panel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: PanelKind
    public var title: String
    public var frame: GridRect
    public var settings: PanelSettings

    public init(id: UUID = UUID(), kind: PanelKind, title: String,
                frame: GridRect, settings: PanelSettings = PanelSettings()) {
        self.id = id
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
        return id.uuidString
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

    // Weather
    public var latitude: Double?
    public var longitude: Double?
    public var locationName: String?

    // Calendar
    public var calendarDaysAhead: Int = 7

    // Health
    public var healthMetric: HealthMetric = .steps

    /// Friendlier names for classes, keyed by the school's course name.
    /// "AP US History A (Sem 1)" → "History".
    public var courseAliases: [String: String] = [:]

    // Feed / calendar presentation
    public var listDisplay: ListDisplayMode = .list

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

    // Alerts — local notification when the panel's value crosses a limit.
    public var alertAbove: Double?
    public var alertBelow: Double?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case refreshSeconds, url, valuePath, seriesPath, pointValuePath, pointLabelPath
        case unit, chartStyle, chartBase
        case progressFormat, progressTotal
        case webClipZoom, webClipSelector, webClipHideSelectors, webClipBlocksAds
        case webClipAutoLogin
        case imageFilter
        case timeZoneID, showsSeconds
        case latitude, longitude, locationName
        case calendarDaysAhead, listDisplay, healthMetric, courseAliases
        case targetDate, text
        case tableHasHeader, tableZebra, tableStatusColoring
        case statusTargets, bridgeKey, mcp, connector
        case accentColorHex, alertAbove, alertBelow
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
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        locationName = try container.decodeIfPresent(String.self, forKey: .locationName)
        calendarDaysAhead = try container.decodeIfPresent(Int.self, forKey: .calendarDaysAhead) ?? 7
        healthMetric = (try? container.decodeIfPresent(HealthMetric.self, forKey: .healthMetric)) ?? .steps
        courseAliases = try container.decodeIfPresent([String: String].self, forKey: .courseAliases) ?? [:]
        listDisplay = (try? container.decodeIfPresent(ListDisplayMode.self, forKey: .listDisplay)) ?? .list
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
        alertAbove = try container.decodeIfPresent(Double.self, forKey: .alertAbove)
        alertBelow = try container.decodeIfPresent(Double.self, forKey: .alertBelow)
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
