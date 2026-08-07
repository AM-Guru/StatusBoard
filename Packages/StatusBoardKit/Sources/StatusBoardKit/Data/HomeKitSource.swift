import Foundation
#if canImport(HomeKit) && !os(macOS)
import HomeKit
#endif

/// Reads the house through HomeKit.
///
/// HomeKit is the one provider that needs no account, no token and no
/// network round trip — the accessories are already paired to this Apple ID
/// and the values arrive over the local network or through a home hub. That
/// makes it the right default for anyone who has it, and it is why this
/// source asks for nothing in the panel settings beyond which room or
/// thermostat to show.
///
/// There is no HomeKit framework on macOS, so Mac boards see HomeKit panels
/// through iCloud sync from an iPhone, iPad or Apple TV — the same
/// arrangement the Health panel already uses.
public enum HomeKitSource {

    public static func fetch(settings: PanelSettings) async -> DataSnapshot? {
        #if canImport(HomeKit) && !os(macOS)
        // The live camera view is a real HomeKit view, not an image we can
        // put in a snapshot — the panel renders it itself, so there is
        // nothing to fetch. Returning nil leaves whatever is on screen alone.
        if settings.homeMode == .camera { return nil }

        switch await HomeKitBridge.shared.authorization() {
        case .granted:
            break
        case .denied:
            return .error("Status Board isn't allowed to see your home. Turn it on in Settings ▸ Privacy & Security ▸ HomeKit.")
        case .noHomes:
            return .error("No HomeKit home set up on this device yet. Add one in the Home app.")
        }

        if settings.homeMode.isThermostat {
            guard var readout = await HomeKitBridge.shared.thermostat(settings: settings) else {
                return .error("No HomeKit thermostat found\(settings.homeTarget.map { " for “\($0)”" } ?? ""). Pick one in the panel's settings.")
            }
            readout.rooms = await HomeKitBridge.shared.roomTemperatures(settings: settings)
            await HomeReadout.attachHistory(to: &readout, settings: settings)
            return .thermostat(readout)
        }

        let report = await HomeKitBridge.shared.sensors(settings: settings)
        guard !report.isEmpty else {
            return .error(settings.homeMode == .activity
                          ? "No motion, door or lock accessories in this home."
                          : "No matching sensors in this home. Check which kinds the panel is showing.")
        }
        return .homeSensors(report)
        #else
        return .error("HomeKit panels work on iPhone, iPad, Apple TV and Apple Watch. Values reach this Mac through iCloud sync.")
        #endif
    }

    /// Thermostats and cameras this device can see, for the settings pickers.
    public static func choices(mode: HomePanelMode, homeName: String?) async -> [HomeDeviceChoice] {
        #if canImport(HomeKit) && !os(macOS)
        return await HomeKitBridge.shared.choices(mode: mode, homeName: homeName)
        #else
        return []
        #endif
    }

    public static func homeNames() async -> [String] {
        #if canImport(HomeKit) && !os(macOS)
        return await HomeKitBridge.shared.homeNames()
        #else
        return []
        #endif
    }

    /// Whether this platform can talk to HomeKit at all — what the inspector
    /// uses to explain itself rather than showing a dead picker.
    public static var isAvailable: Bool {
        #if canImport(HomeKit) && !os(macOS)
        return true
        #else
        return false
        #endif
    }
}

/// The raw-number half of the HomeKit mapping, kept outside the framework
/// guard so it is testable on a Mac — which has no HomeKit at all, and is
/// where the tests run. Getting any of these backwards would report every
/// closed door as open, so they are worth pinning down.
public enum HomeKitMapping {
    /// HomeKit's binary characteristics do not agree on which way round they
    /// are: a contact sensor reports 0 for *detected*, meaning shut, while a
    /// motion sensor reports 1 for detected, meaning movement.
    public static func isActive(kind: HomeSensorKind, raw: Double) -> Bool {
        switch kind {
        case .contact:
            // 0 = contact detected (closed), 1 = not detected (open).
            return raw != 0
        case .lock:
            // 0 = unsecured, 1 = secured, 2 = jammed, 3 = unknown. Anything
            // that is not definitely locked is worth flagging.
            return raw != 1
        default:
            return raw != 0
        }
    }

    public static func status(fromCurrentHeatingCooling raw: Int) -> HVACStatus {
        switch raw {
        case 1: return .heating
        case 2: return .cooling
        case 0: return .off
        default: return .unknown
        }
    }

    public static func mode(fromTargetHeatingCooling raw: Int) -> ThermostatMode {
        switch raw {
        case 0: return .off
        case 1: return .heat
        case 2: return .cool
        case 3: return .auto
        default: return .unknown
        }
    }
}

#if canImport(HomeKit) && !os(macOS)

/// The one live `HMHomeManager` in the process.
///
/// HomeKit hands its homes over asynchronously through a delegate callback
/// that fires once, some time after the manager is created, and creating a
/// second manager per fetch would re-pay that cost every refresh — and, on a
/// hub-mediated home, re-trigger the permission prompt. So there is exactly
/// one, everything waits on the first update, and later refreshes are cheap.
@MainActor
public final class HomeKitBridge: NSObject, HMHomeManagerDelegate {
    public static let shared = HomeKitBridge()

    public enum Authorization: Sendable {
        case granted
        case denied
        case noHomes
    }

    private var manager: HMHomeManager?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var hasUpdated = false
    /// Characteristics already set to push their changes, so the next refresh
    /// can read `value` without a round trip.
    private var notifying = Set<String>()

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Creates the manager on first use and returns once HomeKit has handed
    /// over its homes. Later calls return immediately.
    private func ready() async -> HMHomeManager {
        if let manager, hasUpdated { return manager }
        let manager = self.manager ?? {
            let created = HMHomeManager()
            created.delegate = self
            self.manager = created
            return created
        }()
        guard !hasUpdated else { return manager }

        // HomeKit gives no failure callback: if the user never answers the
        // permission prompt the delegate simply never fires. A deadline keeps
        // the panel's fetch loop from parking forever on it.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    self.waiters.append(continuation)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
            }
            await group.next()
            group.cancelAll()
        }
        return manager
    }

    nonisolated public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.hasUpdated = true
            let waiting = self.waiters
            self.waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    public func authorization() async -> Authorization {
        let manager = await ready()
        let status = manager.authorizationStatus
        if status.contains(.restricted) { return .denied }
        // `.determined` without `.authorized` means the user was asked and
        // said no. Before they answer, neither bit is set and the home list
        // is empty, which reads the same way to a panel.
        if status.contains(.determined) && !status.contains(.authorized) { return .denied }
        return manager.homes.isEmpty ? .noHomes : .granted
    }

    public func homeNames() async -> [String] {
        await ready().homes.map(\.name)
    }

    /// The home a panel is pinned to, or the primary one.
    private func home(named name: String?, in manager: HMHomeManager) -> HMHome? {
        if let name, !name.isEmpty,
           let match = manager.homes.first(where: { $0.name == name }) {
            return match
        }
        return manager.primaryHome ?? manager.homes.first
    }

    // MARK: - Pickers

    public func choices(mode: HomePanelMode, homeName: String?) async -> [HomeDeviceChoice] {
        let manager = await ready()
        guard let home = home(named: homeName, in: manager) else { return [] }
        if mode == .camera {
            return home.accessories
                .filter { !($0.cameraProfiles ?? []).isEmpty }
                .map { HomeDeviceChoice(id: $0.uniqueIdentifier.uuidString, name: $0.name,
                                        room: $0.room?.name, detail: "Camera") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return home.accessories.flatMap { accessory in
            accessory.services
                .filter { $0.serviceType == HMServiceTypeThermostat }
                .map { service in
                    HomeDeviceChoice(id: service.uniqueIdentifier.uuidString,
                                     name: displayName(of: service, in: accessory),
                                     room: accessory.room?.name,
                                     detail: "Thermostat")
                }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// An accessory with one service takes the accessory's name; a multi-
    /// service accessory names each one, so "Hallway" doesn't appear four
    /// times in the picker.
    private func displayName(of service: HMService, in accessory: HMAccessory) -> String {
        let serviceName = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if serviceName.isEmpty || serviceName == accessory.name { return accessory.name }
        return "\(accessory.name) · \(serviceName)"
    }

    /// Accessories with a camera, for the live camera panel.
    public func cameraAccessories(homeName: String?) async -> [HMAccessory] {
        let manager = await ready()
        guard let home = home(named: homeName, in: manager) else { return [] }
        return home.accessories.filter { !($0.cameraProfiles ?? []).isEmpty }
    }

    // MARK: - Sensors

    public func sensors(settings: PanelSettings) async -> HomeSensorReport {
        let manager = await ready()
        guard let home = home(named: settings.homeName, in: manager) else {
            return HomeSensorReport(readings: [], sourceLabel: "HomeKit")
        }

        let wanted = Set(settings.resolvedSensorKinds)
        let rooms = Set(settings.homeRooms)
        var readings: [HomeReading] = []

        for accessory in home.accessories {
            let room = accessory.room?.name
            if !rooms.isEmpty, let room, !rooms.contains(room) { continue }
            if !rooms.isEmpty && room == nil { continue }

            let lowBattery = await batteryIsLow(of: accessory)
            for service in accessory.services {
                // The thermostat's own temperature is its current reading, and
                // a thermostat in every room list is exactly what people want.
                for characteristic in service.characteristics {
                    guard let kind = Self.kind(for: characteristic.characteristicType),
                          wanted.contains(kind) else { continue }
                    guard let reading = await reading(from: characteristic, kind: kind,
                                                      accessory: accessory, service: service,
                                                      room: room, batteryIsLow: lowBattery) else {
                        continue
                    }
                    readings.append(reading)
                }
            }
        }

        // A room panel that also lists every window sensor stops being a room
        // panel, so `.rooms` keeps only what a room *is*.
        if settings.homeMode == .rooms {
            readings = readings.filter { $0.kind == .temperature || $0.kind == .humidity }
        }

        return HomeSensorReport(homeName: home.name,
                                readings: dedupe(readings),
                                sourceLabel: "HomeKit")
    }

    /// Temperatures elsewhere, to sit under a thermostat.
    public func roomTemperatures(settings: PanelSettings) async -> [HomeReading] {
        var roomSettings = settings
        roomSettings.homeMode = .rooms
        roomSettings.homeSensorKinds = [.temperature]
        roomSettings.homeRooms = []
        return await sensors(settings: roomSettings).readings
    }

    private func reading(from characteristic: HMCharacteristic,
                         kind: HomeSensorKind,
                         accessory: HMAccessory,
                         service: HMService,
                         room: String?,
                         batteryIsLow: Bool) async -> HomeReading? {
        guard let number = await value(of: characteristic) else { return nil }
        let id = characteristic.uniqueIdentifier.uuidString
        let name = displayName(of: service, in: accessory)

        var reading = HomeReading(id: id, name: name, room: room, kind: kind,
                                  updatedAt: Date(),
                                  isReachable: accessory.isReachable,
                                  batteryIsLow: batteryIsLow)
        if kind.isBinary {
            reading.isActive = HomeKitMapping.isActive(kind: kind, raw: number.doubleValue)
        } else {
            reading.value = number.doubleValue
        }
        return reading
    }

    /// Reads a characteristic, preferring the value HomeKit already has.
    ///
    /// Turning on notifications is what makes that cached value trustworthy:
    /// the accessory then pushes its changes and every later refresh is free.
    /// Without it each panel would issue a round trip per sensor per minute,
    /// which a Thread network of battery sensors notices.
    private func value(of characteristic: HMCharacteristic) async -> NSNumber? {
        let key = characteristic.uniqueIdentifier.uuidString
        if !notifying.contains(key),
           characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
            notifying.insert(key)
            try? await characteristic.enableNotification(true)
        }
        if let cached = characteristic.value as? NSNumber { return cached }
        try? await characteristic.readValue()
        return characteristic.value as? NSNumber
    }

    private func batteryIsLow(of accessory: HMAccessory) async -> Bool {
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.characteristicType == HMCharacteristicTypeStatusLowBattery {
                if let value = await value(of: characteristic) { return value.intValue == 1 }
            }
        }
        return false
    }

    /// Two accessories can expose the same physical sensor twice (a bridge
    /// and its native pairing), which would draw the room's temperature
    /// twice, sometimes disagreeing.
    private func dedupe(_ readings: [HomeReading]) -> [HomeReading] {
        var seen = Set<String>()
        return readings.filter { reading in
            let key = "\(reading.room ?? "")|\(reading.name)|\(reading.kind.rawValue)"
            return seen.insert(key).inserted
        }
    }

    // MARK: - Thermostat

    public func thermostat(settings: PanelSettings) async -> ThermostatReadout? {
        let manager = await ready()
        guard let home = home(named: settings.homeName, in: manager) else { return nil }

        var found: (accessory: HMAccessory, service: HMService)?
        for accessory in home.accessories {
            for service in accessory.services where service.serviceType == HMServiceTypeThermostat {
                if let target = settings.homeTarget {
                    if service.uniqueIdentifier.uuidString == target
                        || accessory.uniqueIdentifier.uuidString == target
                        || accessory.name == target {
                        found = (accessory, service)
                    }
                } else if found == nil {
                    found = (accessory, service)
                }
            }
        }
        guard let (accessory, service) = found else { return nil }

        var readout = ThermostatReadout(id: service.uniqueIdentifier.uuidString,
                                        name: displayName(of: service, in: accessory),
                                        room: accessory.room?.name,
                                        isOnline: accessory.isReachable,
                                        sourceLabel: "HomeKit",
                                        updatedAt: Date())

        for characteristic in service.characteristics {
            guard let number = await value(of: characteristic) else { continue }
            // HomeKit always reports Celsius on the wire; the temperature
            // units characteristic only says how the accessory's own display
            // is configured, so it is deliberately ignored here.
            switch characteristic.characteristicType {
            case HMCharacteristicTypeCurrentTemperature:
                readout.currentC = number.doubleValue
            case HMCharacteristicTypeTargetTemperature:
                readout.targetC = number.doubleValue
            case HMCharacteristicTypeCurrentRelativeHumidity:
                readout.humidity = number.doubleValue
            case HMCharacteristicTypeHeatingThreshold:
                readout.heatSetpointC = number.doubleValue
            case HMCharacteristicTypeCoolingThreshold:
                readout.coolSetpointC = number.doubleValue
            case HMCharacteristicTypeCurrentHeatingCooling:
                readout.status = HomeKitMapping.status(fromCurrentHeatingCooling: number.intValue)
            case HMCharacteristicTypeTargetHeatingCooling:
                readout.mode = HomeKitMapping.mode(fromTargetHeatingCooling: number.intValue)
            default:
                break
            }
        }

        // In auto the single target is meaningless — the range is what the
        // equipment chases — so it is dropped rather than drawn as a third,
        // contradictory number.
        if readout.mode == .auto, readout.heatSetpointC != nil || readout.coolSetpointC != nil {
            readout.targetC = nil
        }
        readout.fanIsOn = await fanIsOn(in: accessory)
        return readout
    }

    private func fanIsOn(in accessory: HMAccessory) async -> Bool? {
        for service in accessory.services
        where service.serviceType == HMServiceTypeFan
            || service.serviceType == HMServiceTypeVentilationFan {
            for characteristic in service.characteristics
            where characteristic.characteristicType == HMCharacteristicTypeCurrentFanState
                || characteristic.characteristicType == HMCharacteristicTypePowerState {
                if let value = await value(of: characteristic) { return value.intValue > 0 }
            }
        }
        return nil
    }

    // MARK: - Mapping

    static func kind(for characteristicType: String) -> HomeSensorKind? {
        switch characteristicType {
        case HMCharacteristicTypeCurrentTemperature: return .temperature
        case HMCharacteristicTypeCurrentRelativeHumidity: return .humidity
        case HMCharacteristicTypeMotionDetected: return .motion
        case HMCharacteristicTypeOccupancyDetected: return .occupancy
        case HMCharacteristicTypeContactState: return .contact
        case HMCharacteristicTypeCurrentLockMechanismState: return .lock
        case HMCharacteristicTypeCurrentLightLevel: return .light
        case HMCharacteristicTypeAirQuality: return .airQuality
        case HMCharacteristicTypeCarbonDioxideLevel: return .carbonDioxide
        case HMCharacteristicTypeVolatileOrganicCompoundDensity: return .volatileOrganic
        case HMCharacteristicTypePM2_5Density: return .particulate
        case HMCharacteristicTypeSmokeDetected: return .smoke
        case HMCharacteristicTypeCarbonMonoxideDetected: return .carbonMonoxide
        case HMCharacteristicTypeLeakDetected: return .leak
        case HMCharacteristicTypeBatteryLevel: return .battery
        default: return nil
        }
    }

}
#endif
