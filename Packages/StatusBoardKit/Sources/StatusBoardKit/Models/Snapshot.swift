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

    public init(id: String = UUID().uuidString, title: String, link: String? = nil, published: Date? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.published = published
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

    public init(locationName: String, temperatureC: Double, symbolName: String,
                conditionDescription: String, windKPH: Double, days: [Day]) {
        self.locationName = locationName
        self.temperatureC = temperatureC
        self.symbolName = symbolName
        self.conditionDescription = conditionDescription
        self.windKPH = windKPH
        self.days = days
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
