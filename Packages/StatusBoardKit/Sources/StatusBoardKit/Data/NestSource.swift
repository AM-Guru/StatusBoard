import Foundation

/// Reads Nest thermostats through Google's Smart Device Management API.
///
/// Two limits are worth knowing before reading the code, because both shaped
/// it and neither is a bug here:
///
/// * **Nest Temperature Sensors are not devices.** The SDM API returns
///   thermostats, cameras, doorbells and displays; the little satellite
///   sensors people put in bedrooms are visible in the Nest app but have no
///   API representation at all. So "temperature in each room" from Nest means
///   one reading per *thermostat* — which is the whole story in a multi-zone
///   house and only part of it otherwise. The panel says so rather than
///   quietly showing less than expected.
/// * **There is no history.** SDM answers with the present and nothing else,
///   so every trend and every cycling figure on a Nest panel is built from
///   samples Status Board recorded itself (see `HVACHistoryStore`). A panel
///   added this morning has this morning's chart.
///
/// Cameras are deliberately absent: SDM offers them as a WebRTC or RTSP
/// stream negotiated per session, not as an image, so a "camera" mode here
/// would need a media stack and would still fail on the platforms that matter
/// for a wall display. Home Assistant's Nest integration exposes those same
/// cameras as ordinary snapshot entities, which the Home Assistant panel can
/// already show.
public enum NestSource {
    static let base = "https://smartdevicemanagement.googleapis.com/v1"
    static let thermostatType = "sdm.devices.types.THERMOSTAT"

    // MARK: - Panel entry point

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        do {
            let (token, projectID) = try await NestCredentials.shared.authorized()
            let devices = try await devices(token: token, projectID: projectID)
            let thermostats = devices.filter {
                $0["type"]?.stringValue == thermostatType
            }
            guard !thermostats.isEmpty else {
                return .error("No Nest thermostats on this Device Access project. Check that the account you authorized is the one the thermostat is on.")
            }

            if settings.homeMode == .rooms {
                let readings = thermostats.flatMap(readings(fromDevice:))
                return .homeSensors(HomeSensorReport(
                    readings: readings,
                    sourceLabel: "Nest",
                    note: thermostats.count == 1
                        ? "Nest reports one temperature per thermostat. Its separate Temperature Sensors aren't available through Google's API."
                        : nil))
            }

            let chosen: JSONValue?
            if let target = settings.homeTarget, !target.isEmpty {
                chosen = thermostats.first { $0["name"]?.stringValue == target }
                    ?? thermostats.first { deviceID($0["name"]?.stringValue) == target }
            } else {
                chosen = thermostats.first
            }
            guard let device = chosen, var readout = readout(from: device) else {
                return .error("That Nest thermostat is no longer on the account. Pick another in the panel's settings.")
            }

            if settings.showsHomeRoomStrip, thermostats.count > 1 {
                readout.rooms = thermostats.flatMap(readings(fromDevice:))
                    .filter { $0.kind == .temperature }
            }
            await HomeReadout.attachHistory(to: &readout, settings: settings)
            return .thermostat(readout)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Thermostats on the account, for the settings picker.
    public static func choices() async throws -> [HomeDeviceChoice] {
        let (token, projectID) = try await NestCredentials.shared.authorized()
        return try await devices(token: token, projectID: projectID)
            .filter { $0["type"]?.stringValue == thermostatType }
            .compactMap { device in
                guard let name = device["name"]?.stringValue else { return nil }
                return HomeDeviceChoice(id: name,
                                        name: displayName(of: device),
                                        room: room(of: device),
                                        detail: "Thermostat")
            }
    }

    // MARK: - Parsing

    /// SDM nests everything under `traits`, keyed by fully qualified trait
    /// names. A thermostat that is off simply omits some of them, so every
    /// read is optional and the result is whatever could be learned — the
    /// same rule the Tessie parser follows for the same reason.
    public static func readout(from device: JSONValue) -> ThermostatReadout? {
        guard let name = device["name"]?.stringValue else { return nil }
        let traits = device["traits"]

        func trait(_ suffix: String) -> JSONValue? {
            traits?["sdm.devices.traits." + suffix]
        }

        let modeRaw = trait("ThermostatMode")?["mode"]?.stringValue ?? ""
        let ecoMode = trait("ThermostatEco")?["mode"]?.stringValue ?? "OFF"
        let isEco = ecoMode != "OFF"

        var readout = ThermostatReadout(
            id: name,
            name: displayName(of: device),
            room: room(of: device),
            currentC: trait("Temperature")?["ambientTemperatureCelsius"]?.doubleValue,
            humidity: trait("Humidity")?["ambientHumidityPercent"]?.doubleValue,
            mode: isEco ? .eco : mode(from: modeRaw),
            status: status(from: trait("ThermostatHvac")?["status"]?.stringValue),
            isOnline: trait("Connectivity")?["status"]?.stringValue != "OFFLINE",
            holdLabel: isEco ? "Eco" : nil,
            sourceLabel: "Nest",
            updatedAt: Date())

        // In Eco the thermostat holds the Eco setpoints, not the scheduled
        // ones — reading the ordinary setpoint trait then shows a target the
        // equipment is not chasing.
        let setpoint = isEco ? trait("ThermostatEco") : trait("ThermostatTemperatureSetpoint")
        let heat = setpoint?["heatCelsius"]?.doubleValue
        let cool = setpoint?["coolCelsius"]?.doubleValue
        switch (modeRaw, heat, cool) {
        case ("HEAT", let heat?, _):
            readout.targetC = heat
        case ("COOL", _, let cool?):
            readout.targetC = cool
        default:
            readout.heatSetpointC = heat
            readout.coolSetpointC = cool
        }

        let fanMode = trait("Fan")?["timerMode"]?.stringValue
        if let fanMode { readout.fanIsOn = fanMode == "ON" }
        return readout
    }

    /// A thermostat as a room temperature (and humidity) reading.
    static func readings(fromDevice device: JSONValue) -> [HomeReading] {
        guard let name = device["name"]?.stringValue else { return [] }
        let traits = device["traits"]
        let label = displayName(of: device)
        let place = room(of: device)
        let isOnline = traits?["sdm.devices.traits.Connectivity"]?["status"]?.stringValue != "OFFLINE"

        var readings: [HomeReading] = []
        if let temperature = traits?["sdm.devices.traits.Temperature"]?["ambientTemperatureCelsius"]?.doubleValue {
            readings.append(HomeReading(id: "\(name)#temperature", name: label, room: place,
                                        kind: .temperature, value: temperature,
                                        updatedAt: Date(), isReachable: isOnline))
        }
        if let humidity = traits?["sdm.devices.traits.Humidity"]?["ambientHumidityPercent"]?.doubleValue {
            readings.append(HomeReading(id: "\(name)#humidity", name: label, room: place,
                                        kind: .humidity, value: humidity,
                                        updatedAt: Date(), isReachable: isOnline))
        }
        return readings
    }

    /// The room, which SDM carries as the display name of the device's parent
    /// relation rather than as a field on the device.
    static func room(of device: JSONValue) -> String? {
        let name = device["parentRelations"]?.arrayValue?
            .compactMap { $0["displayName"]?.stringValue }
            .first { !$0.isEmpty }
        return name
    }

    /// The name people gave it, falling back to the room, then to the opaque
    /// resource id's last path component — never to the whole resource name,
    /// which is 90 characters of project UUID.
    static func displayName(of device: JSONValue) -> String {
        if let custom = device["traits"]?["sdm.devices.traits.Info"]?["customName"]?.stringValue,
           !custom.isEmpty {
            return custom
        }
        if let room = room(of: device), !room.isEmpty { return room }
        return deviceID(device["name"]?.stringValue) ?? "Nest Thermostat"
    }

    static func deviceID(_ resourceName: String?) -> String? {
        resourceName?.split(separator: "/").last.map(String.init)
    }

    static func mode(from raw: String) -> ThermostatMode {
        switch raw {
        case "HEAT": return .heat
        case "COOL": return .cool
        case "HEATCOOL": return .auto
        case "OFF": return .off
        default: return .unknown
        }
    }

    static func status(from raw: String?) -> HVACStatus {
        switch raw {
        case "HEATING": return .heating
        case "COOLING": return .cooling
        case "OFF": return .off
        default: return .unknown
        }
    }

    // MARK: - Requests

    static func devices(token: String, projectID: String) async throws -> [JSONValue] {
        let json = try await request(path: "/enterprises/\(projectID)/devices", token: token)
        return json["devices"]?.arrayValue ?? []
    }

    static func request(path: String, token: String) async throws -> JSONValue {
        guard let url = URL(string: base + path) else {
            throw SBError.message("Invalid Nest request")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONValue.parse(data)
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return json }

        let detail = json["error"]?["message"]?.stringValue
        switch http.statusCode {
        case 401:
            throw SBError.message("Google rejected the Nest sign-in. Connect the account again in the panel's settings.")
        case 403:
            throw SBError.message("That Device Access project can't see any devices. Make sure the Smart Device Management API is enabled and the account completed the Nest device picker. \(detail ?? "")")
        case 404:
            throw SBError.message("No such Device Access project. Check the project id in the panel's settings.")
        case 429:
            // SDM's quota is per structure and unforgiving; the fix is
            // almost always a slower refresh rather than a retry.
            throw SBError.message("Google is rate limiting Nest requests. Try a refresh interval of a few minutes.")
        default:
            throw SBError.message("Nest HTTP \(http.statusCode)\(detail.map { ": \($0)" } ?? "")")
        }
    }
}
