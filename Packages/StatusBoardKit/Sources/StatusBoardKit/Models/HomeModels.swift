import Foundation

/// The house, as three very different services describe it.
///
/// HomeKit, Home Assistant and Google Nest disagree about almost everything —
/// units, naming, what counts as a device, whether rooms exist at all — so
/// each source normalizes into the types here and every renderer, summary and
/// widget reads only these. Adding a fourth provider should mean writing one
/// more source, not touching a single view.
///
/// Everything is Foundation-only on purpose: the analysis in `HVACAnalyzer`
/// is the interesting part of this feature and it has to be unit-testable
/// without a house attached.

// MARK: - Sensors

/// What a reading *is*, which is what decides how it draws and what "bad"
/// means. Deliberately coarser than any one platform's characteristic list:
/// a HomeKit contact sensor, a Home Assistant `binary_sensor.door` and a
/// Nest doorbell all land on `.contact`.
public enum HomeSensorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case temperature
    case humidity
    case motion
    case occupancy
    case contact
    case lock
    case light
    case airQuality
    case carbonDioxide
    case volatileOrganic
    case particulate
    case smoke
    case carbonMonoxide
    case leak
    case battery
    case power
    case energy
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .temperature: return "Temperature"
        case .humidity: return "Humidity"
        case .motion: return "Motion"
        case .occupancy: return "Occupancy"
        case .contact: return "Doors & Windows"
        case .lock: return "Locks"
        case .light: return "Light Level"
        case .airQuality: return "Air Quality"
        case .carbonDioxide: return "CO₂"
        case .volatileOrganic: return "VOC"
        case .particulate: return "PM2.5"
        case .smoke: return "Smoke"
        case .carbonMonoxide: return "Carbon Monoxide"
        case .leak: return "Leak"
        case .battery: return "Battery"
        case .power: return "Power"
        case .energy: return "Energy"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .humidity: return "humidity"
        case .motion: return "figure.walk.motion"
        case .occupancy: return "sensor.fill"
        case .contact: return "door.left.hand.open"
        case .lock: return "lock.fill"
        case .light: return "sun.max"
        case .airQuality: return "aqi.medium"
        case .carbonDioxide: return "carbon.dioxide.cloud"
        case .volatileOrganic: return "aqi.low"
        case .particulate: return "aqi.high"
        case .smoke: return "smoke.fill"
        case .carbonMonoxide: return "carbon.monoxide.cloud"
        case .leak: return "drop.triangle"
        case .battery: return "battery.25"
        case .power: return "bolt.fill"
        case .energy: return "chart.bar.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// Readings whose interesting state is on/off rather than a number.
    public var isBinary: Bool {
        switch self {
        case .motion, .occupancy, .contact, .lock, .smoke, .carbonMonoxide, .leak:
            return true
        default:
            return false
        }
    }

    /// The unit a numeric reading of this kind is normalized to. Temperature
    /// is the exception — it is always stored in Celsius and converted at
    /// draw time, so the same snapshot reads correctly on a device set to
    /// Fahrenheit and one set to Celsius.
    public var canonicalUnit: String? {
        switch self {
        case .temperature: return "°C"
        case .humidity, .battery: return "%"
        case .light: return "lx"
        case .carbonDioxide: return "ppm"
        case .volatileOrganic, .particulate: return "µg/m³"
        case .power: return "W"
        case .energy: return "kWh"
        default: return nil
        }
    }

    /// The set a new panel starts with — the four things people actually put
    /// on a wall display. The rest are opt-in.
    public static let defaultSelection: [HomeSensorKind] = [
        .temperature, .humidity, .motion, .contact,
    ]

    /// Kinds a "motion / activity" panel watches.
    public static let activitySelection: [HomeSensorKind] = [
        .motion, .occupancy, .contact, .lock,
    ]
}

/// One value from one accessory, already normalized.
public struct HomeReading: Codable, Hashable, Sendable, Identifiable {
    /// Stable per accessory *and* characteristic — a multi-sensor reports
    /// temperature and humidity under two ids, or the two rows would collide.
    public var id: String
    public var name: String
    /// Nil when the provider has no concept of rooms, or the accessory has
    /// not been assigned to one.
    public var room: String?
    public var kind: HomeSensorKind
    /// Numeric readings, in `kind.canonicalUnit`.
    public var value: Double?
    /// On/off readings: motion detected, contact open, door unlocked.
    public var isActive: Bool?
    /// A state word the provider gave us, when neither of the above fits.
    public var text: String?
    public var updatedAt: Date?
    /// False when the accessory is unreachable — drawn dimmed rather than
    /// hidden, because a sensor that stopped answering is worth seeing.
    public var isReachable: Bool
    public var batteryIsLow: Bool

    public init(id: String, name: String, room: String? = nil,
                kind: HomeSensorKind, value: Double? = nil,
                isActive: Bool? = nil, text: String? = nil,
                updatedAt: Date? = nil, isReachable: Bool = true,
                batteryIsLow: Bool = false) {
        self.id = id
        self.name = name
        self.room = room
        self.kind = kind
        self.value = value
        self.isActive = isActive
        self.text = text
        self.updatedAt = updatedAt
        self.isReachable = isReachable
        self.batteryIsLow = batteryIsLow
    }

    /// Hand-written so snapshots cached by an older build keep loading, the
    /// same rule the rest of the models follow.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        room = try container.decodeIfPresent(String.self, forKey: .room)
        kind = (try? container.decodeIfPresent(HomeSensorKind.self, forKey: .kind))
            .flatMap { $0 } ?? .other
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        isReachable = try container.decodeIfPresent(Bool.self, forKey: .isReachable) ?? true
        batteryIsLow = try container.decodeIfPresent(Bool.self, forKey: .batteryIsLow) ?? false
    }

    /// How urgent this reading is, in the shared good/warn/bad vocabulary the
    /// panel styles already speak.
    public enum Tone: String, Codable, Sendable {
        case neutral, good, warn, bad
    }

    public var tone: Tone {
        guard isReachable else { return .warn }
        switch kind {
        case .smoke, .carbonMonoxide, .leak:
            return isActive == true ? .bad : .good
        case .motion, .occupancy:
            return isActive == true ? .good : .neutral
        case .contact:
            return isActive == true ? .warn : .neutral
        case .lock:
            // `isActive` means unlocked, so an open lock is the notable state.
            return isActive == true ? .warn : .good
        case .carbonDioxide:
            guard let value else { return .neutral }
            if value >= 2000 { return .bad }
            if value >= 1000 { return .warn }
            return .good
        case .particulate:
            guard let value else { return .neutral }
            if value >= 55 { return .bad }
            if value >= 35 { return .warn }
            return .good
        case .airQuality:
            // HomeKit's 1…5 scale: 1 excellent, 5 poor.
            guard let value else { return .neutral }
            if value >= 4 { return .bad }
            if value >= 3 { return .warn }
            return .good
        case .battery:
            guard let value else { return batteryIsLow ? .warn : .neutral }
            if value <= 10 { return .bad }
            if value <= 25 { return .warn }
            return .neutral
        default:
            return batteryIsLow ? .warn : .neutral
        }
    }

    /// The short string the panel draws — "68°", "Open", "43%".
    public func displayValue(units: WeatherUnits) -> String {
        if kind == .temperature, let value {
            return SBTemperature.short(value, units: units)
        }
        if let text, !text.isEmpty { return text }
        if kind.isBinary, let isActive {
            switch kind {
            case .motion: return isActive ? "Motion" : "Clear"
            case .occupancy: return isActive ? "Occupied" : "Empty"
            case .contact: return isActive ? "Open" : "Closed"
            case .lock: return isActive ? "Unlocked" : "Locked"
            case .smoke: return isActive ? "Smoke" : "Clear"
            case .carbonMonoxide: return isActive ? "CO" : "Clear"
            case .leak: return isActive ? "Leak" : "Dry"
            default: return isActive ? "On" : "Off"
            }
        }
        guard let value else { return "—" }
        let rounded = abs(value) >= 100 || value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
        guard let unit = kind.canonicalUnit else { return rounded }
        return "\(rounded)\(unit == "%" ? "" : " ")\(unit)"
    }
}

/// Everything a sensor panel draws: readings plus where they came from.
public struct HomeSensorReport: Codable, Hashable, Sendable {
    public var homeName: String?
    public var readings: [HomeReading]
    /// "HomeKit", "Home Assistant", "Nest" — shown small so a board with all
    /// three on it stays legible.
    public var sourceLabel: String?
    /// Set when a provider can only see part of the house and saying so is
    /// more useful than silently showing less (Nest, which does not expose
    /// its own temperature sensors).
    public var note: String?

    public init(homeName: String? = nil, readings: [HomeReading],
                sourceLabel: String? = nil, note: String? = nil) {
        self.homeName = homeName
        self.readings = readings
        self.sourceLabel = sourceLabel
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homeName = try container.decodeIfPresent(String.self, forKey: .homeName)
        readings = try container.decodeIfPresent([HomeReading].self, forKey: .readings) ?? []
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public var isEmpty: Bool { readings.isEmpty }

    /// Readings grouped by room, rooms in alphabetical order with the
    /// unassigned ones last, and each room's readings in a stable order so
    /// the panel doesn't reshuffle itself on every refresh.
    public var byRoom: [(room: String, readings: [HomeReading])] {
        var buckets: [String: [HomeReading]] = [:]
        for reading in readings {
            let room = reading.room?.trimmingCharacters(in: .whitespacesAndNewlines)
            buckets[(room?.isEmpty == false ? room! : "Elsewhere"), default: []].append(reading)
        }
        return buckets
            .map { (room: $0.key, readings: $0.value.sorted { sortKey($0) < sortKey($1) }) }
            .sorted { lhs, rhs in
                if (lhs.room == "Elsewhere") != (rhs.room == "Elsewhere") {
                    return rhs.room == "Elsewhere"
                }
                return lhs.room.localizedStandardCompare(rhs.room) == .orderedAscending
            }
    }

    /// Temperature first, then humidity, then everything else by name — the
    /// order someone reads a room in.
    private func sortKey(_ reading: HomeReading) -> String {
        let rank: Int
        switch reading.kind {
        case .temperature: rank = 0
        case .humidity: rank = 1
        case .motion, .occupancy: rank = 2
        case .contact, .lock: rank = 3
        default: rank = 4
        }
        return "\(rank)\(reading.name)"
    }

    /// The house's average temperature, for the one-line summaries.
    public var averageTemperatureC: Double? {
        let values = readings.filter { $0.kind == .temperature }.compactMap(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public var activeReadings: [HomeReading] {
        readings.filter { $0.isActive == true }
    }
}

// MARK: - Thermostats

public enum ThermostatMode: String, Codable, CaseIterable, Sendable {
    case off
    case heat
    case cool
    /// Heat *and* cool, holding a range. HomeKit calls it auto, Nest HEATCOOL.
    case auto
    case eco
    case fanOnly
    case dry
    case unknown

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .heat: return "Heat"
        case .cool: return "Cool"
        case .auto: return "Auto"
        case .eco: return "Eco"
        case .fanOnly: return "Fan"
        case .dry: return "Dry"
        case .unknown: return "—"
        }
    }

    public var symbolName: String {
        switch self {
        case .off: return "power"
        case .heat: return "flame.fill"
        case .cool: return "snowflake"
        case .auto: return "arrow.up.arrow.down"
        case .eco: return "leaf.fill"
        case .fanOnly: return "fan.fill"
        case .dry: return "humidity.fill"
        case .unknown: return "questionmark"
        }
    }
}

/// What the equipment is doing *right now*, as opposed to what it was asked
/// to do. The difference between these two is most of the diagnosis.
public enum HVACStatus: String, Codable, CaseIterable, Sendable {
    case off
    case heating
    case cooling
    case fan
    case unknown

    public var displayName: String {
        switch self {
        case .off: return "Idle"
        case .heating: return "Heating"
        case .cooling: return "Cooling"
        case .fan: return "Fan"
        case .unknown: return "—"
        }
    }

    public var symbolName: String {
        switch self {
        case .off: return "pause.circle"
        case .heating: return "flame.fill"
        case .cooling: return "snowflake"
        case .fan: return "fan.fill"
        case .unknown: return "questionmark"
        }
    }

    /// Whether the compressor or burner is actually drawing power. The fan
    /// running on its own is not a cycle, which matters: a fan that never
    /// stops would otherwise read as one enormous "run".
    public var isConditioning: Bool { self == .heating || self == .cooling }
}

/// One moment in a thermostat's life, recorded every refresh. The whole
/// trend and diagnosis are built from a list of these.
public struct HVACSample: Codable, Hashable, Sendable {
    public var date: Date
    public var indoorC: Double?
    /// The setpoint in force at the time — the one the equipment is chasing,
    /// so in a heat/cool range this is whichever end applies.
    public var targetC: Double?
    public var outdoorC: Double?
    public var humidity: Double?
    public var status: HVACStatus

    public init(date: Date, indoorC: Double? = nil, targetC: Double? = nil,
                outdoorC: Double? = nil, humidity: Double? = nil,
                status: HVACStatus = .unknown) {
        self.date = date
        self.indoorC = indoorC
        self.targetC = targetC
        self.outdoorC = outdoorC
        self.humidity = humidity
        self.status = status
    }
}

/// One thing worth telling someone about their heating or cooling.
public struct HVACIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable, Comparable {
        case info
        case notice
        case warning
        case critical

        var rank: Int {
            switch self {
            case .info: return 0
            case .notice: return 1
            case .warning: return 2
            case .critical: return 3
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: String
    public var severity: Severity
    public var title: String
    /// The evidence, in a sentence. Always includes the numbers behind the
    /// claim — a diagnosis nobody can check is worse than no diagnosis.
    public var detail: String

    public init(id: String, severity: Severity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

/// What `HVACAnalyzer` made of a window of samples.
public struct HVACDiagnostics: Codable, Hashable, Sendable {
    /// How far back the numbers below look.
    public var windowHours: Double
    /// Completed on→off runs of the compressor or burner in the window.
    public var cycles: Int
    public var cyclesPerHour: Double
    public var averageRunMinutes: Double?
    public var averageOffMinutes: Double?
    public var shortestRunMinutes: Double?
    /// Share of the window spent actively heating or cooling, 0…1.
    public var runtimeFraction: Double
    public var heatingMinutes: Double
    public var coolingMinutes: Double
    /// How far the room drifted from the setpoint, worst case.
    public var maxDeviationC: Double?
    /// Median spacing between samples. Everything above is only as precise
    /// as this, and the panel says so rather than implying more.
    public var resolutionMinutes: Double
    public var sampleCount: Int
    public var issues: [HVACIssue]

    public init(windowHours: Double = 0, cycles: Int = 0, cyclesPerHour: Double = 0,
                averageRunMinutes: Double? = nil, averageOffMinutes: Double? = nil,
                shortestRunMinutes: Double? = nil, runtimeFraction: Double = 0,
                heatingMinutes: Double = 0, coolingMinutes: Double = 0,
                maxDeviationC: Double? = nil, resolutionMinutes: Double = 0,
                sampleCount: Int = 0, issues: [HVACIssue] = []) {
        self.windowHours = windowHours
        self.cycles = cycles
        self.cyclesPerHour = cyclesPerHour
        self.averageRunMinutes = averageRunMinutes
        self.averageOffMinutes = averageOffMinutes
        self.shortestRunMinutes = shortestRunMinutes
        self.runtimeFraction = runtimeFraction
        self.heatingMinutes = heatingMinutes
        self.coolingMinutes = coolingMinutes
        self.maxDeviationC = maxDeviationC
        self.resolutionMinutes = resolutionMinutes
        self.sampleCount = sampleCount
        self.issues = issues
    }

    /// Whether there is enough history to say anything at all. A panel added
    /// five minutes ago should say "still watching", not "all clear".
    public var hasEnoughHistory: Bool { sampleCount >= 12 && windowHours >= 1 }

    public var worstSeverity: HVACIssue.Severity? {
        issues.map(\.severity).max()
    }
}

/// Everything a thermostat panel draws.
public struct ThermostatReadout: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var room: String?
    public var currentC: Double?
    public var humidity: Double?
    /// A single setpoint, when the thermostat holds one.
    public var targetC: Double?
    /// The two ends of a range, when it is in auto/heat-cool.
    public var heatSetpointC: Double?
    public var coolSetpointC: Double?
    public var mode: ThermostatMode
    public var status: HVACStatus
    public var fanIsOn: Bool?
    public var isOnline: Bool
    public var outdoorC: Double?
    /// "Eco", "Away" — whatever the provider calls its energy-saving state.
    public var holdLabel: String?
    public var sourceLabel: String?
    public var updatedAt: Date?
    /// The recorded history behind the trend chart, oldest first.
    public var samples: [HVACSample]
    public var diagnostics: HVACDiagnostics?
    /// Temperatures elsewhere in the house, when the provider knows them —
    /// what turns a thermostat panel into a whole-house view.
    public var rooms: [HomeReading]

    public init(id: String, name: String, room: String? = nil,
                currentC: Double? = nil, humidity: Double? = nil,
                targetC: Double? = nil, heatSetpointC: Double? = nil,
                coolSetpointC: Double? = nil, mode: ThermostatMode = .unknown,
                status: HVACStatus = .unknown, fanIsOn: Bool? = nil,
                isOnline: Bool = true, outdoorC: Double? = nil,
                holdLabel: String? = nil, sourceLabel: String? = nil,
                updatedAt: Date? = nil, samples: [HVACSample] = [],
                diagnostics: HVACDiagnostics? = nil, rooms: [HomeReading] = []) {
        self.id = id
        self.name = name
        self.room = room
        self.currentC = currentC
        self.humidity = humidity
        self.targetC = targetC
        self.heatSetpointC = heatSetpointC
        self.coolSetpointC = coolSetpointC
        self.mode = mode
        self.status = status
        self.fanIsOn = fanIsOn
        self.isOnline = isOnline
        self.outdoorC = outdoorC
        self.holdLabel = holdLabel
        self.sourceLabel = sourceLabel
        self.updatedAt = updatedAt
        self.samples = samples
        self.diagnostics = diagnostics
        self.rooms = rooms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        room = try container.decodeIfPresent(String.self, forKey: .room)
        currentC = try container.decodeIfPresent(Double.self, forKey: .currentC)
        humidity = try container.decodeIfPresent(Double.self, forKey: .humidity)
        targetC = try container.decodeIfPresent(Double.self, forKey: .targetC)
        heatSetpointC = try container.decodeIfPresent(Double.self, forKey: .heatSetpointC)
        coolSetpointC = try container.decodeIfPresent(Double.self, forKey: .coolSetpointC)
        mode = (try? container.decodeIfPresent(ThermostatMode.self, forKey: .mode))
            .flatMap { $0 } ?? .unknown
        status = (try? container.decodeIfPresent(HVACStatus.self, forKey: .status))
            .flatMap { $0 } ?? .unknown
        fanIsOn = try container.decodeIfPresent(Bool.self, forKey: .fanIsOn)
        isOnline = try container.decodeIfPresent(Bool.self, forKey: .isOnline) ?? true
        outdoorC = try container.decodeIfPresent(Double.self, forKey: .outdoorC)
        holdLabel = try container.decodeIfPresent(String.self, forKey: .holdLabel)
        sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        samples = try container.decodeIfPresent([HVACSample].self, forKey: .samples) ?? []
        diagnostics = try container.decodeIfPresent(HVACDiagnostics.self, forKey: .diagnostics)
        rooms = try container.decodeIfPresent([HomeReading].self, forKey: .rooms) ?? []
    }

    /// The setpoint the equipment is actually chasing. In a heat/cool range
    /// that is whichever end matches what it is doing, and when it is idle,
    /// whichever end the room is closer to — so the trend chart draws one
    /// line that means something rather than two that mostly don't.
    public var activeSetpointC: Double? {
        if let targetC { return targetC }
        switch status {
        case .heating: return heatSetpointC ?? targetC
        case .cooling: return coolSetpointC ?? targetC
        default: break
        }
        switch mode {
        case .heat: return heatSetpointC
        case .cool: return coolSetpointC
        default: break
        }
        guard let currentC else { return heatSetpointC ?? coolSetpointC }
        switch (heatSetpointC, coolSetpointC) {
        case let (heat?, cool?):
            return abs(currentC - heat) <= abs(currentC - cool) ? heat : cool
        case let (heat?, nil): return heat
        case let (nil, cool?): return cool
        default: return nil
        }
    }

    /// How the setpoint reads on screen: one number, or a range.
    public func setpointText(units: WeatherUnits) -> String? {
        if mode == .off { return nil }
        if let targetC { return SBTemperature.short(targetC, units: units) }
        switch (heatSetpointC, coolSetpointC) {
        case let (heat?, cool?):
            return "\(SBTemperature.short(heat, units: units)) – \(SBTemperature.short(cool, units: units))"
        case let (heat?, nil): return SBTemperature.short(heat, units: units)
        case let (nil, cool?): return SBTemperature.short(cool, units: units)
        default: return nil
        }
    }

    /// Signed distance from the setpoint. Positive means the room is warmer
    /// than asked for.
    public var deviationC: Double? {
        guard let currentC, let setpoint = activeSetpointC else { return nil }
        return currentC - setpoint
    }
}

// MARK: - Panel modes

/// What a home panel is for. One kind per provider, one mode per question —
/// which keeps three providers × six questions from becoming eighteen kinds
/// in the "add panel" menu.
public enum HomePanelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Temperature (and humidity) room by room.
    case rooms
    /// Whatever sensors you pick, whatever they measure.
    case sensors
    /// Motion, occupancy, doors and locks — what is happening right now.
    case activity
    /// One thermostat: current, setpoint, mode, what the equipment is doing.
    case thermostat
    /// The same thermostat as a chart over time.
    case trend
    /// The same thermostat's health: cycling, runtime, anything wrong.
    case diagnostics
    /// A camera.
    case camera

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rooms: return "Room Temperatures"
        case .sensors: return "Sensors"
        case .activity: return "Motion & Doors"
        case .thermostat: return "Thermostat"
        case .trend: return "Temperature Trend"
        case .diagnostics: return "Equipment Health"
        case .camera: return "Camera"
        }
    }

    public var detail: String {
        switch self {
        case .rooms: return "Every room that reports a temperature, grouped and sorted."
        case .sensors: return "Pick the sensors you want; anything they measure is shown."
        case .activity: return "Motion, occupancy, doors, windows and locks as they change."
        case .thermostat: return "Current temperature, setpoint, mode and what the equipment is doing."
        case .trend: return "Indoor temperature against the setpoint, with heating and cooling runs marked."
        case .diagnostics: return "Cycling rate, runtime and warnings such as short cycling."
        case .camera: return "A live view or the latest frame."
        }
    }

    /// Whether this mode produces a thermostat reading, and so needs a device
    /// chosen and a history recorded.
    public var isThermostat: Bool {
        self == .thermostat || self == .trend || self == .diagnostics
    }
}

/// Which of the three services a panel talks to. Kept as its own type so the
/// sources, the settings UI and the analyzer can all reason about provider
/// limits without switching on `PanelKind` in a dozen places.
public enum HomeProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case homeKit
    case homeAssistant
    case nest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .homeKit: return "HomeKit"
        case .homeAssistant: return "Home Assistant"
        case .nest: return "Nest"
        }
    }

    /// The modes this provider can actually answer.
    ///
    /// Nest's Smart Device Management API exposes thermostats and nothing
    /// else useful here: its own Temperature Sensors are not returned as
    /// devices, and camera access is a WebRTC stream rather than an image.
    /// Offering those modes and failing at fetch time would be worse than
    /// not offering them.
    public var supportedModes: [HomePanelMode] {
        switch self {
        case .homeKit:
            return [.rooms, .sensors, .activity, .thermostat, .trend, .diagnostics, .camera]
        case .homeAssistant:
            return [.rooms, .sensors, .activity, .thermostat, .trend, .diagnostics, .camera]
        case .nest:
            return [.rooms, .thermostat, .trend, .diagnostics]
        }
    }

    public func supports(_ mode: HomePanelMode) -> Bool {
        supportedModes.contains(mode)
    }
}

/// One thing a panel can be pointed at, as offered by the settings picker.
///
/// Typing an entity id or a Nest device resource name from memory is a
/// mistake waiting to happen, so every provider can list what it has and the
/// inspector shows the list — the same reasoning as the Tessie vehicle picker.
public struct HomeDeviceChoice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var room: String?
    /// "Thermostat", "Camera", "Temperature" — what it is, for the subtitle.
    public var detail: String?

    public init(id: String, name: String, room: String? = nil, detail: String? = nil) {
        self.id = id
        self.name = name
        self.room = room
        self.detail = detail
    }

    /// "Hallway · Thermostat" — where it is and what it is, without repeating
    /// the name that is already the row's title.
    public var subtitle: String? {
        let parts = [room, detail].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Temperature formatting

/// One place that turns stored Celsius into what a panel shows.
///
/// Every home reading is stored in Celsius no matter what the provider sent,
/// so a board synced from a Fahrenheit device to a Celsius one reads right on
/// both. That only works if nothing converts on the way *in*.
public enum SBTemperature {
    public static func usesFahrenheit(_ units: WeatherUnits) -> Bool {
        switch units {
        case .celsius: return false
        case .fahrenheit: return true
        case .automatic: return !localeIsMetric
        }
    }

    public static var localeIsMetric: Bool {
        Locale.current.measurementSystem != .us
    }

    public static func converted(_ celsius: Double, units: WeatherUnits) -> Double {
        usesFahrenheit(units) ? celsius * 9 / 5 + 32 : celsius
    }

    /// "68°" — the form that goes in a tile, where the scale is obvious from
    /// everything around it.
    public static func short(_ celsius: Double, units: WeatherUnits) -> String {
        "\(Int(converted(celsius, units: units).rounded()))°"
    }

    /// "68°F" — the form that has to stand on its own, in a spoken summary
    /// or a Lock Screen complication.
    public static func full(_ celsius: Double, units: WeatherUnits) -> String {
        "\(Int(converted(celsius, units: units).rounded()))°\(usesFahrenheit(units) ? "F" : "C")"
    }

    /// A temperature *difference*, which scales but does not offset — the
    /// mistake that turns a 1 °C swing into a 34 °F one.
    public static func delta(_ celsiusDelta: Double, units: WeatherUnits) -> String {
        let value = usesFahrenheit(units) ? celsiusDelta * 9 / 5 : celsiusDelta
        return String(format: "%.1f°", value)
    }
}
