import Foundation

/// One Tesla, flattened from Tessie's `/state` response into the things a wall
/// display actually shows.
///
/// Values stay in the API's own units — miles, miles per hour, degrees
/// Celsius, bar — and are converted only for display. `units` carries what the
/// car's own screen is set to, so a panel reads the same as the dash no matter
/// which device is showing the board.
///
/// Everything decodes through `decodeIfPresent`. Tesla omits whole sub-objects
/// depending on how awake the car is and which firmware it runs, and a
/// snapshot written by an older build still has to load.
public struct TessieVehicle: Codable, Hashable, Sendable {
    public var vin: String
    public var name: String
    public var connection: Connection
    /// When the car itself reported this — not when we fetched it.
    public var capturedAt: Date?

    public var drive: Drive
    public var place: Place
    /// Present only while a navigation route is active.
    public var route: Route?
    public var battery: Battery
    public var climate: Climate
    public var security: Security
    public var system: System
    public var units: Units

    public init(vin: String, name: String, connection: Connection = .unknown,
                capturedAt: Date? = nil, drive: Drive = Drive(), place: Place = Place(),
                route: Route? = nil, battery: Battery = Battery(),
                climate: Climate = Climate(), security: Security = Security(),
                system: System = System(), units: Units = Units()) {
        self.vin = vin
        self.name = name
        self.connection = connection
        self.capturedAt = capturedAt
        self.drive = drive
        self.place = place
        self.route = route
        self.battery = battery
        self.climate = climate
        self.security = security
        self.system = system
        self.units = units
    }

    /// Which layout the panel should use. Gear is the honest signal; a car
    /// rolling with no gear reported still counts as driving.
    public var isDriving: Bool {
        switch drive.gear {
        case .drive, .reverse, .neutral: return true
        case .park: return false
        case .unknown: return (drive.speedMPH ?? 0) > 0
        }
    }

    public var isCharging: Bool { battery.state == .charging || battery.state == .starting }

    /// Whether the car is reachable at all. An asleep car still reports its
    /// last known state, which is exactly what a dashboard wants.
    public var isAsleep: Bool { connection == .asleep || connection == .offline }

    // MARK: - Sub-payloads

    public struct Drive: Codable, Hashable, Sendable {
        public var gear: Gear = .unknown
        public var speedMPH: Double?
        public var headingDegrees: Double?
        /// The posted limit for the road the car is on, from OpenStreetMap.
        public var postedLimitMPH: Double?
        /// Tesla's own Speed Limit Mode cap, when the driver has it switched
        /// on. This is a governor the owner set, not the posted limit.
        public var governorLimitMPH: Double?
        public var odometerMiles: Double?
        public var powerKW: Double?

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case gear, speedMPH, headingDegrees, postedLimitMPH, governorLimitMPH
            case odometerMiles, powerKW
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gear = try c.decodeIfPresent(Gear.self, forKey: .gear) ?? .unknown
            speedMPH = try c.decodeIfPresent(Double.self, forKey: .speedMPH)
            headingDegrees = try c.decodeIfPresent(Double.self, forKey: .headingDegrees)
            postedLimitMPH = try c.decodeIfPresent(Double.self, forKey: .postedLimitMPH)
            governorLimitMPH = try c.decodeIfPresent(Double.self, forKey: .governorLimitMPH)
            odometerMiles = try c.decodeIfPresent(Double.self, forKey: .odometerMiles)
            powerKW = try c.decodeIfPresent(Double.self, forKey: .powerKW)
        }

        /// How far over the posted limit the car is, in mph. Negative or nil
        /// when it is at or under.
        public var overLimitMPH: Double? {
            guard let speedMPH, let postedLimitMPH, speedMPH > postedLimitMPH else { return nil }
            return speedMPH - postedLimitMPH
        }
    }

    public struct Place: Codable, Hashable, Sendable {
        public var latitude: Double?
        public var longitude: Double?
        public var address: String?
        /// The name of a location saved in Tessie, e.g. "Home" or "Work".
        public var savedLocation: String?

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case latitude, longitude, address, savedLocation
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
            address = try c.decodeIfPresent(String.self, forKey: .address)
            savedLocation = try c.decodeIfPresent(String.self, forKey: .savedLocation)
        }

        public var hasCoordinate: Bool { latitude != nil && longitude != nil }

        /// The shortest honest label for where the car is.
        public var shortDescription: String? {
            if let savedLocation, !savedLocation.isEmpty { return savedLocation }
            guard let address, !address.isEmpty else { return nil }
            // Street plus town is enough; the country and postcode are noise
            // on a panel this size.
            let parts = address.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return parts.prefix(2).joined(separator: ", ")
        }
    }

    public struct Route: Codable, Hashable, Sendable {
        public var destination: String?
        public var latitude: Double?
        public var longitude: Double?
        public var minutesToArrival: Double?
        public var milesToArrival: Double?
        public var trafficDelayMinutes: Double?
        /// Predicted battery percentage on arrival.
        public var energyAtArrival: Double?

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case destination, latitude, longitude, minutesToArrival, milesToArrival
            case trafficDelayMinutes, energyAtArrival
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            destination = try c.decodeIfPresent(String.self, forKey: .destination)
            latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
            minutesToArrival = try c.decodeIfPresent(Double.self, forKey: .minutesToArrival)
            milesToArrival = try c.decodeIfPresent(Double.self, forKey: .milesToArrival)
            trafficDelayMinutes = try c.decodeIfPresent(Double.self, forKey: .trafficDelayMinutes)
            energyAtArrival = try c.decodeIfPresent(Double.self, forKey: .energyAtArrival)
        }

        public var hasCoordinate: Bool { latitude != nil && longitude != nil }

        /// Clock time the car is expected to arrive, measured from when the
        /// car reported the estimate rather than from now — otherwise the ETA
        /// slides forward every time the panel redraws.
        public func arrival(from capturedAt: Date?) -> Date? {
            guard let minutesToArrival, minutesToArrival > 0 else { return nil }
            return (capturedAt ?? Date()).addingTimeInterval(minutesToArrival * 60)
        }
    }

    public struct Battery: Codable, Hashable, Sendable {
        /// State of charge, 0–100.
        public var level: Double?
        public var usableLevel: Double?
        public var rangeMiles: Double?
        public var chargeLimit: Double?
        public var state: ChargingState = .unknown
        public var powerKW: Double?
        public var voltage: Double?
        public var amps: Double?
        public var minutesToFull: Double?
        public var energyAddedKWh: Double?
        public var isPluggedIn: Bool = false
        public var isFastCharging: Bool = false

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case level, usableLevel, rangeMiles, chargeLimit, state, powerKW
            case voltage, amps, minutesToFull, energyAddedKWh, isPluggedIn, isFastCharging
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            level = try c.decodeIfPresent(Double.self, forKey: .level)
            usableLevel = try c.decodeIfPresent(Double.self, forKey: .usableLevel)
            rangeMiles = try c.decodeIfPresent(Double.self, forKey: .rangeMiles)
            chargeLimit = try c.decodeIfPresent(Double.self, forKey: .chargeLimit)
            state = try c.decodeIfPresent(ChargingState.self, forKey: .state) ?? .unknown
            powerKW = try c.decodeIfPresent(Double.self, forKey: .powerKW)
            voltage = try c.decodeIfPresent(Double.self, forKey: .voltage)
            amps = try c.decodeIfPresent(Double.self, forKey: .amps)
            minutesToFull = try c.decodeIfPresent(Double.self, forKey: .minutesToFull)
            energyAddedKWh = try c.decodeIfPresent(Double.self, forKey: .energyAddedKWh)
            isPluggedIn = try c.decodeIfPresent(Bool.self, forKey: .isPluggedIn) ?? false
            isFastCharging = try c.decodeIfPresent(Bool.self, forKey: .isFastCharging) ?? false
        }

        /// When charging finishes, anchored to the car's own timestamp for the
        /// same reason the route ETA is.
        public func chargeComplete(from capturedAt: Date?) -> Date? {
            guard let minutesToFull, minutesToFull > 0 else { return nil }
            return (capturedAt ?? Date()).addingTimeInterval(minutesToFull * 60)
        }
    }

    public struct Climate: Codable, Hashable, Sendable {
        public var insideC: Double?
        public var outsideC: Double?
        public var isOn: Bool = false
        public var isPreconditioning: Bool = false
        public var isDefrosting: Bool = false
        /// Cabin Overheat Protection, which runs with the car parked.
        public var cabinOverheatProtection: String?

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case insideC, outsideC, isOn, isPreconditioning, isDefrosting, cabinOverheatProtection
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            insideC = try c.decodeIfPresent(Double.self, forKey: .insideC)
            outsideC = try c.decodeIfPresent(Double.self, forKey: .outsideC)
            isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
            isPreconditioning = try c.decodeIfPresent(Bool.self, forKey: .isPreconditioning) ?? false
            isDefrosting = try c.decodeIfPresent(Bool.self, forKey: .isDefrosting) ?? false
            cabinOverheatProtection = try c.decodeIfPresent(String.self, forKey: .cabinOverheatProtection)
        }
    }

    public struct Security: Codable, Hashable, Sendable {
        public var isLocked: Bool?
        public var sentryMode: Bool?
        public var sentryAvailable: Bool = false
        public var isUserPresent: Bool = false
        public var valetMode: Bool = false
        /// Doors, frunk and trunk that are standing open, already labelled.
        public var openings: [String] = []
        /// Windows that are not fully closed, already labelled.
        public var openWindows: [String] = []

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case isLocked, sentryMode, sentryAvailable, isUserPresent, valetMode
            case openings, openWindows
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked)
            sentryMode = try c.decodeIfPresent(Bool.self, forKey: .sentryMode)
            sentryAvailable = try c.decodeIfPresent(Bool.self, forKey: .sentryAvailable) ?? false
            isUserPresent = try c.decodeIfPresent(Bool.self, forKey: .isUserPresent) ?? false
            valetMode = try c.decodeIfPresent(Bool.self, forKey: .valetMode) ?? false
            openings = try c.decodeIfPresent([String].self, forKey: .openings) ?? []
            openWindows = try c.decodeIfPresent([String].self, forKey: .openWindows) ?? []
        }

        public var isButtonedUp: Bool {
            (isLocked ?? true) && openings.isEmpty && openWindows.isEmpty
        }
    }

    public struct System: Codable, Hashable, Sendable {
        public var softwareVersion: String?
        public var updateStatus: String?
        public var updateVersion: String?
        public var updateDownloadPercent: Double?
        public var updateInstallPercent: Double?
        /// Tesla's driver-assist tier, e.g. "TeslaAP3". This describes what
        /// the car is *capable* of; Tessie's REST API publishes no live
        /// engagement state, so the panel never claims Autopilot is steering.
        public var driverAssist: String?
        public var smartSummonAvailable: Bool = false
        public var tires: [TirePressure] = []

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case softwareVersion, updateStatus, updateVersion, updateDownloadPercent
            case updateInstallPercent, driverAssist, smartSummonAvailable, tires
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            softwareVersion = try c.decodeIfPresent(String.self, forKey: .softwareVersion)
            updateStatus = try c.decodeIfPresent(String.self, forKey: .updateStatus)
            updateVersion = try c.decodeIfPresent(String.self, forKey: .updateVersion)
            updateDownloadPercent = try c.decodeIfPresent(Double.self, forKey: .updateDownloadPercent)
            updateInstallPercent = try c.decodeIfPresent(Double.self, forKey: .updateInstallPercent)
            driverAssist = try c.decodeIfPresent(String.self, forKey: .driverAssist)
            smartSummonAvailable = try c.decodeIfPresent(Bool.self, forKey: .smartSummonAvailable) ?? false
            tires = try c.decodeIfPresent([TirePressure].self, forKey: .tires) ?? []
        }

        /// A software update that is downloading, downloaded or installing.
        public var hasPendingUpdate: Bool {
            guard let updateStatus, !updateStatus.isEmpty else { return false }
            return updateStatus.lowercased() != "unavailable"
        }

        /// Plain-English name for the driver-assist hardware the car carries.
        public var driverAssistName: String? {
            guard let driverAssist, !driverAssist.isEmpty else { return nil }
            switch driverAssist.lowercased() {
            case "teslaap1": return "Autopilot (HW1)"
            case "teslaap2": return "Autopilot (HW2)"
            case "teslaap3": return "Full Self-Driving computer"
            case "teslaap4": return "AI4 computer"
            case "monocam", "none": return "No driver assist"
            default: return driverAssist
            }
        }
    }

    public struct TirePressure: Codable, Hashable, Sendable, Identifiable {
        /// "FL", "FR", "RL", "RR".
        public var position: String
        public var bar: Double

        public var id: String { position }

        public init(position: String, bar: Double) {
            self.position = position
            self.bar = bar
        }

        public var psi: Double { bar * 14.503773773 }
    }

    /// What the car's own screen is set to. Falls back to the device locale
    /// when Tesla doesn't say.
    public struct Units: Codable, Hashable, Sendable {
        public var metricDistance: Bool
        public var fahrenheit: Bool

        public init(metricDistance: Bool = Units.localeIsMetric,
                    fahrenheit: Bool = !Units.localeIsMetric) {
            self.metricDistance = metricDistance
            self.fahrenheit = fahrenheit
        }

        public static var localeIsMetric: Bool {
            Locale.current.measurementSystem != .us
        }

        private enum CodingKeys: String, CodingKey {
            case metricDistance, fahrenheit
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            metricDistance = try c.decodeIfPresent(Bool.self, forKey: .metricDistance)
                ?? Units.localeIsMetric
            fahrenheit = try c.decodeIfPresent(Bool.self, forKey: .fahrenheit)
                ?? !Units.localeIsMetric
        }
    }

    // MARK: - Enumerations
    //
    // Every one of these decodes an unrecognised value to `.unknown` rather
    // than throwing. Tesla adds states with firmware releases, and a single
    // new string must not cost the panel its whole snapshot.

    public enum Connection: String, Codable, Sendable {
        case online, asleep, waking, offline, unknown

        public init(from decoder: Decoder) throws {
            let raw = try? String(from: decoder)
            self = raw.flatMap { Connection(rawValue: $0.lowercased()) } ?? .unknown
        }

        public var displayName: String {
            switch self {
            case .online: return "Online"
            case .asleep: return "Asleep"
            case .waking: return "Waking"
            case .offline: return "Offline"
            case .unknown: return "Unknown"
            }
        }
    }

    public enum Gear: String, Codable, Sendable {
        case park = "P"
        case reverse = "R"
        case neutral = "N"
        case drive = "D"
        case unknown = "?"

        public init(from decoder: Decoder) throws {
            let raw = try? String(from: decoder)
            self = raw.flatMap { Gear(rawValue: $0.uppercased()) } ?? .unknown
        }

        public var displayName: String {
            switch self {
            case .park: return "Park"
            case .reverse: return "Reverse"
            case .neutral: return "Neutral"
            case .drive: return "Drive"
            case .unknown: return "—"
            }
        }
    }

    public enum ChargingState: String, Codable, Sendable {
        case disconnected = "Disconnected"
        case stopped = "Stopped"
        case charging = "Charging"
        case complete = "Complete"
        case starting = "Starting"
        case noPower = "NoPower"
        case unknown = "Unknown"

        public init(from decoder: Decoder) throws {
            let raw = try? String(from: decoder)
            self = raw.flatMap { ChargingState(rawValue: $0) } ?? .unknown
        }

        public var displayName: String {
            switch self {
            case .disconnected: return "Unplugged"
            case .stopped: return "Stopped"
            case .charging: return "Charging"
            case .complete: return "Charged"
            case .starting: return "Starting"
            case .noPower: return "No power"
            case .unknown: return "—"
            }
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case vin, name, connection, capturedAt
        case drive, place, route, battery, climate, security, system, units
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vin = try c.decodeIfPresent(String.self, forKey: .vin) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Tesla"
        connection = try c.decodeIfPresent(Connection.self, forKey: .connection) ?? .unknown
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
        drive = try c.decodeIfPresent(Drive.self, forKey: .drive) ?? Drive()
        place = try c.decodeIfPresent(Place.self, forKey: .place) ?? Place()
        route = try c.decodeIfPresent(Route.self, forKey: .route)
        battery = try c.decodeIfPresent(Battery.self, forKey: .battery) ?? Battery()
        climate = try c.decodeIfPresent(Climate.self, forKey: .climate) ?? Climate()
        security = try c.decodeIfPresent(Security.self, forKey: .security) ?? Security()
        system = try c.decodeIfPresent(System.self, forKey: .system) ?? System()
        units = try c.decodeIfPresent(Units.self, forKey: .units) ?? Units()
    }
}

// MARK: - Field selection

/// Which layout a Tessie panel is showing. The panel picks one automatically
/// from the car's gear, so the board rearranges itself when someone drives
/// away — but it can also be pinned, which is what you want when you are
/// laying a board out at your desk.
public enum TessieContext: String, Codable, CaseIterable, Sendable, Identifiable {
    case parked
    case driving

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// One thing a Tessie panel can show. The panel is built from an ordered list
/// of these per context: the first one that has data becomes the headline, the
/// rest become tiles, and the map (wherever it sits in the list) gets its own
/// block.
public enum TessieField: String, Codable, CaseIterable, Sendable, Identifiable {
    case battery
    case range
    case charging
    case chargeComplete
    case speed
    case gear
    case map
    case location
    case navigation
    case arrival
    case lock
    case sentry
    case openings
    case climate
    case insideTemp
    case outsideTemp
    case odometer
    case tires
    case driverAssist
    case software
    case connection

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .battery: return "Battery"
        case .range: return "Range"
        case .charging: return "Charging"
        case .chargeComplete: return "Charge Complete"
        case .speed: return "Speed"
        case .gear: return "Gear"
        case .map: return "Map"
        case .location: return "Location"
        case .navigation: return "Navigation"
        case .arrival: return "Arrival"
        case .lock: return "Locked"
        case .sentry: return "Sentry Mode"
        case .openings: return "Doors & Windows"
        case .climate: return "Climate"
        case .insideTemp: return "Inside Temperature"
        case .outsideTemp: return "Outside Temperature"
        case .odometer: return "Odometer"
        case .tires: return "Tire Pressure"
        case .driverAssist: return "Autopilot / FSD"
        case .software: return "Software"
        case .connection: return "Connection"
        }
    }

    public var symbolName: String {
        switch self {
        case .battery: return "battery.75percent"
        case .range: return "arrow.left.and.right"
        case .charging: return "bolt.fill"
        case .chargeComplete: return "bolt.badge.clock"
        case .speed: return "speedometer"
        case .gear: return "shift"
        case .map: return "map"
        case .location: return "mappin.and.ellipse"
        case .navigation: return "location.north.line.fill"
        case .arrival: return "flag.checkered"
        case .lock: return "lock.fill"
        case .sentry: return "video.fill"
        case .openings: return "door.left.hand.open"
        case .climate: return "fan.fill"
        case .insideTemp: return "thermometer.medium"
        case .outsideTemp: return "thermometer.sun"
        case .odometer: return "gauge.with.dots.needle.bottom.50percent"
        case .tires: return "circle.dotted"
        case .driverAssist: return "steeringwheel"
        case .software: return "arrow.down.circle"
        case .connection: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Parked: what you check from the kitchen — charge, where it is, whether
    /// it's shut and watching.
    public static let defaultParked: [TessieField] = [
        .battery, .charging, .map, .location, .lock, .sentry, .climate,
    ]

    /// Driving: what matters while it's moving — how fast, where it's headed,
    /// and whether it'll get there.
    public static let defaultDriving: [TessieField] = [
        .speed, .navigation, .map, .arrival, .battery, .range,
    ]
}
