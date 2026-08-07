import Foundation

/// Reads a Tesla's live state from Tessie.
///
/// Tessie proxies and caches Tesla's own fleet API, so `GET /{vin}/state`
/// answers instantly with the last known state without waking a sleeping car —
/// which is exactly what a wall display wants. Nothing here ever sends a
/// command; the panel is a window, not a key fob.
public enum TessieSource {
    static let base = "https://api.tessie.com"

    /// A car, as listed by `/vehicles` — enough for the settings picker.
    public struct VehicleSummary: Sendable, Hashable, Identifiable {
        public var vin: String
        public var name: String
        public var isActive: Bool

        public var id: String { vin }
    }

    // MARK: - Panel entry point

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        // Falls back to whatever another Tesla panel was signed in with.
        let config = await TessieCredentials.resolved(settings.connector)
        guard let apiKey = config.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return .error("Add your Tessie API key in the panel settings. Create one at tessie.com under Settings → API.")
        }
        let vin = config.query?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        do {
            var vehicle: TessieVehicle
            if let vin, !vin.isEmpty {
                let json = try await request(path: "/\(vin)/state", apiKey: apiKey)
                vehicle = parse(state: json, fallbackVIN: vin)
            } else {
                // No VIN chosen yet: show the first car on the account rather
                // than an error. `/vehicles` already embeds each car's state,
                // so this costs no extra round trip.
                guard let first = try await firstVehicleState(apiKey: apiKey) else {
                    return .error("No vehicles on this Tessie account")
                }
                vehicle = parse(state: first.state, fallbackVIN: first.vin)
            }

            // `/state` carries coordinates but no street address — that lives
            // only behind `/location`, so it costs a second request, and only
            // when the panel is actually showing a place.
            if needsAddress(settings), !vehicle.vin.isEmpty,
               let location = try? await request(path: "/\(vehicle.vin)/location",
                                                 apiKey: apiKey) {
                merge(location: location, into: &vehicle)
            }

            // Look up the posted limit only while the car is actually moving.
            // A parked car has no road to ask about, and every lookup is a
            // request to a volunteer-run service.
            if settingsShowSpeed(settings, isDriving: vehicle.isDriving),
               let latitude = vehicle.place.latitude,
               let longitude = vehicle.place.longitude {
                vehicle.drive.postedLimitMPH = await RoadSpeedLimit.lookup(latitude: latitude,
                                                                          longitude: longitude)
            }
            return .vehicle(vehicle)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Whether either field list asks for speed. There is no point querying a
    /// speed limit for a panel that shows battery and doors.
    static func settingsShowSpeed(_ settings: PanelSettings, isDriving: Bool) -> Bool {
        guard isDriving else { return false }
        return settings.tessieDrivingFields.contains(.speed)
            || settings.tessieParkedFields.contains(.speed)
    }

    /// Whether either field list wants a place name.
    static func needsAddress(_ settings: PanelSettings) -> Bool {
        let wanted: Set<TessieField> = [.location, .map]
        return !Set(settings.tessieParkedFields).isDisjoint(with: wanted)
            || !Set(settings.tessieDrivingFields).isDisjoint(with: wanted)
    }

    /// Folds a `/location` response into a vehicle parsed from `/state`.
    /// The coordinates only fill in gaps: `/state` is the fresher of the two.
    static func merge(location: JSONValue, into vehicle: inout TessieVehicle) {
        if let address = location["address"]?.stringValue, !address.isEmpty {
            vehicle.place.address = address
        }
        if let saved = location["saved_location"]?.stringValue, !saved.isEmpty {
            vehicle.place.savedLocation = saved
        }
        if vehicle.place.latitude == nil { vehicle.place.latitude = location["latitude"]?.doubleValue }
        if vehicle.place.longitude == nil { vehicle.place.longitude = location["longitude"]?.doubleValue }
    }

    // MARK: - Requests

    public static func vehicles(apiKey: String) async throws -> [VehicleSummary] {
        let json = try await request(path: "/vehicles", apiKey: apiKey)
        return (json["results"]?.arrayValue ?? []).compactMap { entry in
            let state = entry["last_state"]
            guard let vin = entry["vin"]?.stringValue ?? state?["vin"]?.stringValue else {
                return nil
            }
            let name = state?["display_name"]?.stringValue ?? state?["vehicle_state"]?["vehicle_name"]?.stringValue
            return VehicleSummary(vin: vin,
                                  name: (name?.isEmpty == false ? name! : vin),
                                  isActive: entry["is_active"]?.doubleValue != 0)
        }
    }

    static func firstVehicleState(apiKey: String) async throws -> (vin: String, state: JSONValue)? {
        let json = try await request(path: "/vehicles", apiKey: apiKey)
        for entry in json["results"]?.arrayValue ?? [] {
            guard let state = entry["last_state"] else { continue }
            let vin = entry["vin"]?.stringValue ?? state["vin"]?.stringValue ?? ""
            return (vin, state)
        }
        return nil
    }

    static func request(path: String, apiKey: String) async throws -> JSONValue {
        guard let url = URL(string: base + path) else {
            throw SBError.message("Invalid Tessie request")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 401, 403:
                throw SBError.message("Tessie rejected the API key — create a new one at tessie.com under Settings → API")
            case 404:
                throw SBError.message("Tessie has no vehicle with that VIN")
            case 429:
                throw SBError.message("Tessie is rate limiting — try a slower refresh")
            default:
                throw SBError.message("Tessie HTTP \(http.statusCode)")
            }
        }
        return try JSONValue.parse(data)
    }

    // MARK: - Parsing

    /// Flattens Tessie's `/state` response. Tesla omits whole sub-objects
    /// depending on how awake the car is, so every read is optional and the
    /// result is whatever could be learned.
    public static func parse(state: JSONValue, fallbackVIN: String) -> TessieVehicle {
        let drive = state["drive_state"]
        let charge = state["charge_state"]
        let climate = state["climate_state"]
        let vehicleState = state["vehicle_state"]
        let config = state["vehicle_config"]
        let gui = state["gui_settings"]

        let vin = state["vin"]?.stringValue ?? fallbackVIN
        let name = state["display_name"]?.stringValue
            ?? vehicleState?["vehicle_name"]?.stringValue
            ?? "Tesla"

        var vehicle = TessieVehicle(vin: vin, name: name)
        vehicle.connection = TessieVehicle.Connection(
            rawValue: state["state"]?.stringValue?.lowercased() ?? "") ?? .unknown
        vehicle.capturedAt = timestamp(drive?["timestamp"] ?? vehicleState?["timestamp"])

        // Units — mirror the car's own screen so the panel and the dash agree.
        vehicle.units = TessieVehicle.Units(
            metricDistance: (gui?["gui_distance_units"]?.stringValue?.hasPrefix("km"))
                ?? TessieVehicle.Units.localeIsMetric,
            fahrenheit: gui?["gui_temperature_units"]?.stringValue.map { $0.uppercased() == "F" }
                ?? !TessieVehicle.Units.localeIsMetric)

        // Drive
        vehicle.drive.gear = TessieVehicle.Gear(
            rawValue: drive?["shift_state"]?.stringValue?.uppercased() ?? "") ?? .unknown
        vehicle.drive.speedMPH = drive?["speed"]?.doubleValue
        vehicle.drive.headingDegrees = drive?["heading"]?.doubleValue
        vehicle.drive.powerKW = drive?["power"]?.doubleValue
        vehicle.drive.odometerMiles = vehicleState?["odometer"]?.doubleValue
        if let limitMode = vehicleState?["speed_limit_mode"],
           limitMode["active"]?.doubleValue == 1 {
            vehicle.drive.governorLimitMPH = limitMode["current_limit_mph"]?.doubleValue
        }

        // Location
        vehicle.place.latitude = drive?["latitude"]?.doubleValue
            ?? drive?["native_latitude"]?.doubleValue
        vehicle.place.longitude = drive?["longitude"]?.doubleValue
            ?? drive?["native_longitude"]?.doubleValue
        vehicle.place.address = state["address"]?.stringValue
        vehicle.place.savedLocation = state["saved_location"]?.stringValue

        // Navigation. Tesla leaves the whole active_route_* family in place
        // with stale values after a route ends, so the destination name is
        // what decides whether there is a route at all.
        if let destination = drive?["active_route_destination"]?.stringValue,
           !destination.isEmpty {
            var route = TessieVehicle.Route()
            route.destination = destination
            route.latitude = drive?["active_route_latitude"]?.doubleValue
            route.longitude = drive?["active_route_longitude"]?.doubleValue
            route.minutesToArrival = drive?["active_route_minutes_to_arrival"]?.doubleValue
            route.milesToArrival = drive?["active_route_miles_to_arrival"]?.doubleValue
            route.trafficDelayMinutes = drive?["active_route_traffic_minutes_delay"]?.doubleValue
            route.energyAtArrival = drive?["active_route_energy_at_arrival"]?.doubleValue
            vehicle.route = route
        }

        // Battery and charging
        vehicle.battery.level = charge?["battery_level"]?.doubleValue
        vehicle.battery.usableLevel = charge?["usable_battery_level"]?.doubleValue
        vehicle.battery.rangeMiles = charge?["battery_range"]?.doubleValue
            ?? charge?["est_battery_range"]?.doubleValue
        vehicle.battery.chargeLimit = charge?["charge_limit_soc"]?.doubleValue
        vehicle.battery.state = TessieVehicle.ChargingState(
            rawValue: charge?["charging_state"]?.stringValue ?? "") ?? .unknown
        vehicle.battery.powerKW = charge?["charger_power"]?.doubleValue
        vehicle.battery.voltage = charge?["charger_voltage"]?.doubleValue
        vehicle.battery.amps = charge?["charger_actual_current"]?.doubleValue
        vehicle.battery.minutesToFull = charge?["minutes_to_full_charge"]?.doubleValue
            ?? charge?["time_to_full_charge"]?.doubleValue.map { $0 * 60 }
        vehicle.battery.energyAddedKWh = charge?["charge_energy_added"]?.doubleValue
        vehicle.battery.isPluggedIn = charge?["charge_port_latch"]?.stringValue == "Engaged"
            || (charge?["charge_port_door_open"]?.doubleValue == 1
                && vehicle.battery.state != .disconnected)
        vehicle.battery.isFastCharging = charge?["fast_charger_present"]?.doubleValue == 1

        // Climate
        vehicle.climate.insideC = climate?["inside_temp"]?.doubleValue
        vehicle.climate.outsideC = climate?["outside_temp"]?.doubleValue
        vehicle.climate.isOn = climate?["is_climate_on"]?.doubleValue == 1
        vehicle.climate.isPreconditioning = climate?["is_preconditioning"]?.doubleValue == 1
        vehicle.climate.isDefrosting = climate?["is_front_defroster_on"]?.doubleValue == 1
            || climate?["is_rear_defroster_on"]?.doubleValue == 1
        vehicle.climate.cabinOverheatProtection = climate?["cabin_overheat_protection"]?.stringValue

        // Security
        vehicle.security.isLocked = vehicleState?["locked"].flatMap { $0.doubleValue.map { $0 == 1 } }
        vehicle.security.sentryMode = vehicleState?["sentry_mode"].flatMap { $0.doubleValue.map { $0 == 1 } }
        vehicle.security.sentryAvailable = vehicleState?["sentry_mode_available"]?.doubleValue == 1
        vehicle.security.isUserPresent = vehicleState?["is_user_present"]?.doubleValue == 1
        vehicle.security.valetMode = vehicleState?["valet_mode"]?.doubleValue == 1
        vehicle.security.openings = openings(in: vehicleState)
        vehicle.security.openWindows = openWindows(in: vehicleState)

        // Software and driver assist
        vehicle.system.softwareVersion = vehicleState?["car_version"]?.stringValue
        if let update = vehicleState?["software_update"] {
            let status = update["status"]?.stringValue
            vehicle.system.updateStatus = (status?.isEmpty == false) ? status : nil
            vehicle.system.updateVersion = update["version"]?.stringValue
            vehicle.system.updateDownloadPercent = update["download_perc"]?.doubleValue
            vehicle.system.updateInstallPercent = update["install_perc"]?.doubleValue
        }
        vehicle.system.driverAssist = config?["driver_assist"]?.stringValue
        vehicle.system.smartSummonAvailable = vehicleState?["smart_summon_available"]?.doubleValue == 1
        vehicle.system.tires = tires(in: vehicleState)

        return vehicle
    }

    // MARK: - Parsing helpers

    /// Tesla stamps some timestamps in milliseconds and others in seconds.
    /// Anything past the year 2200 in seconds is really milliseconds.
    static func timestamp(_ value: JSONValue?) -> Date? {
        guard let raw = value?.doubleValue, raw > 0 else { return nil }
        let seconds = raw > 7_258_118_400 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    static func openings(in state: JSONValue?) -> [String] {
        // 0 means shut; anything else is an open-angle code.
        let doors: [(String, String)] = [
            ("df", "Driver door"), ("dr", "Driver rear door"),
            ("pf", "Passenger door"), ("pr", "Passenger rear door"),
            ("ft", "Frunk"), ("rt", "Trunk"),
        ]
        return doors.compactMap { key, label in
            guard let value = state?[key]?.doubleValue, value != 0 else { return nil }
            return label
        }
    }

    static func openWindows(in state: JSONValue?) -> [String] {
        let windows: [(String, String)] = [
            ("fd_window", "Driver front"), ("fp_window", "Passenger front"),
            ("rd_window", "Driver rear"), ("rp_window", "Passenger rear"),
        ]
        return windows.compactMap { key, label in
            guard let value = state?[key]?.doubleValue, value != 0 else { return nil }
            return label
        }
    }

    static func tires(in state: JSONValue?) -> [TessieVehicle.TirePressure] {
        let positions: [(String, String)] = [
            ("tpms_pressure_fl", "FL"), ("tpms_pressure_fr", "FR"),
            ("tpms_pressure_rl", "RL"), ("tpms_pressure_rr", "RR"),
        ]
        return positions.compactMap { key, label in
            guard let bar = state?[key]?.doubleValue, bar > 0 else { return nil }
            return TessieVehicle.TirePressure(position: label, bar: bar)
        }
    }
}
