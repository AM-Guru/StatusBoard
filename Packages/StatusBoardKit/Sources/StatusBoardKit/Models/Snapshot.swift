import Foundation

/// The unified payload every data source produces and every panel renders.
public enum DataSnapshot: Codable, Hashable, Sendable {
    case text(String)
    case number(Double, unit: String?)
    case series(SeriesData)
    case table(TableData)
    case feed([FeedItem])
    case weather(WeatherReport)
    case statuses([ServiceStatus])
    case image(Data)
    case grades([CourseGrade])
    case schedule([ScheduledClass])
    case assignments(AssignmentDigest)
    case vehicle(TessieVehicle)
    case homeSensors(HomeSensorReport)
    case thermostat(ThermostatReadout)
    case error(String)
}

/// A snapshot plus the moment it was captured.
public struct SnapshotRecord: Codable, Hashable, Sendable {
    public var snapshot: DataSnapshot
    public var updatedAt: Date

    public init(snapshot: DataSnapshot, updatedAt: Date = Date()) {
        self.snapshot = snapshot
        self.updatedAt = updatedAt
    }
}

public struct SeriesPoint: Codable, Hashable, Sendable {
    public var label: String?
    public var date: Date?
    public var value: Double

    public init(label: String? = nil, date: Date? = nil, value: Double) {
        self.label = label
        self.date = date
        self.value = value
    }
}

public struct SeriesData: Codable, Hashable, Sendable {
    public var points: [SeriesPoint]
    public var unit: String?

    public init(points: [SeriesPoint], unit: String? = nil) {
        self.points = points
        self.unit = unit
    }
}

public struct TableData: Codable, Hashable, Sendable {
    public var columns: [String]
    public var rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

public struct FeedItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var link: String?
    public var published: Date?
    /// Which feed this item came from, when a panel merges several. Nil for
    /// single-source panels and for items pushed over the bridge.
    public var sourceName: String?
    /// The source site's favicon, already downscaled to a small PNG. Carried
    /// in the snapshot rather than fetched at render time so widgets, the
    /// watch and tvOS — none of which run the fetcher — still show it.
    public var sourceIcon: Data?

    public init(id: String = UUID().uuidString, title: String, link: String? = nil,
                published: Date? = nil, sourceName: String? = nil, sourceIcon: Data? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.published = published
        self.sourceName = sourceName
        self.sourceIcon = sourceIcon
    }

    /// The host the item links to, e.g. "arstechnica.com" — the fallback label
    /// when a feed declines to name itself.
    public var linkHost: String? {
        guard let link, let host = URL(string: link)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

public struct WeatherReport: Codable, Hashable, Sendable {
    public struct Day: Codable, Hashable, Sendable, Identifiable {
        public var id: String { dateLabel }
        public var dateLabel: String
        public var highC: Double
        public var lowC: Double
        public var symbolName: String

        public init(dateLabel: String, highC: Double, lowC: Double, symbolName: String) {
            self.dateLabel = dateLabel
            self.highC = highC
            self.lowC = lowC
            self.symbolName = symbolName
        }
    }

    public var locationName: String
    public var temperatureC: Double
    public var symbolName: String
    public var conditionDescription: String
    public var windKPH: Double
    public var days: [Day]
    /// WMO weather code, kept so the panel can pick an animated sky rather
    /// than reverse-engineering one from the symbol name.
    public var code: Int
    /// Whether the sun is up where the report is from — the other half of
    /// choosing a sky. Defaults to true for reports written before this existed.
    public var isDaytime: Bool
    public var humidity: Double?
    public var feelsLikeC: Double?
    /// Where the numbers came from: "Open-Meteo", a station ID, or the user's
    /// own station. Shown small under the condition.
    public var sourceLabel: String?
    /// When the observation itself was taken, when the source reports it.
    public var observedAt: Date?

    public init(locationName: String, temperatureC: Double, symbolName: String,
                conditionDescription: String, windKPH: Double, days: [Day],
                code: Int = -1, isDaytime: Bool = true, humidity: Double? = nil,
                feelsLikeC: Double? = nil, sourceLabel: String? = nil,
                observedAt: Date? = nil) {
        self.locationName = locationName
        self.temperatureC = temperatureC
        self.symbolName = symbolName
        self.conditionDescription = conditionDescription
        self.windKPH = windKPH
        self.days = days
        self.code = code
        self.isDaytime = isDaytime
        self.humidity = humidity
        self.feelsLikeC = feelsLikeC
        self.sourceLabel = sourceLabel
        self.observedAt = observedAt
    }

    /// Hand-written so snapshots cached by an older build still decode — the
    /// snapshot file is a local cache, but losing it would blank every panel
    /// until the next refresh.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locationName = try container.decode(String.self, forKey: .locationName)
        temperatureC = try container.decode(Double.self, forKey: .temperatureC)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        conditionDescription = try container.decode(String.self, forKey: .conditionDescription)
        windKPH = try container.decode(Double.self, forKey: .windKPH)
        days = try container.decode([Day].self, forKey: .days)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? -1
        isDaytime = try container.decodeIfPresent(Bool.self, forKey: .isDaytime) ?? true
        humidity = try container.decodeIfPresent(Double.self, forKey: .humidity)
        feelsLikeC = try container.decodeIfPresent(Double.self, forKey: .feelsLikeC)
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
    }
}

public struct ServiceStatus: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case up, degraded, down, unknown
    }

    public var id: String
    public var name: String
    public var state: State
    public var latencyMS: Double?
    public var detail: String?

    public init(id: String = UUID().uuidString, name: String, state: State,
                latencyMS: Double? = nil, detail: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.latencyMS = latencyMS
        self.detail = detail
    }
}
