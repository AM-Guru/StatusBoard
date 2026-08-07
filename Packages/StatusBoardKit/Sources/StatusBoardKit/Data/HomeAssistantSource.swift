import Foundation

/// Reads the house through Home Assistant's REST API.
///
/// Home Assistant is the broadest of the three providers — it already speaks
/// to Z-Wave, Zigbee, Matter, Ecobee, Nest and everything else in one place —
/// and the only one that keeps history of its own. So this source does two
/// things the others cannot: it groups sensors by *area*, and it backfills a
/// new trend panel from the recorder so the chart isn't blank on day one.
///
/// Everything here is a plain `URLSession` call with a bearer token, which
/// means it works identically on every platform, including tvOS and the
/// watch, and inside widgets.
public enum HomeAssistantSource {

    // MARK: - Panel entry point

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        let config = await HomeAssistantCredentials.resolved(settings.connector)
        guard let base = HomeAssistantCredentials.normalizedURL(config.projectURL) else {
            return .error("Add your Home Assistant address in the panel settings, e.g. homeassistant.local:8123")
        }
        guard let token = HomeAssistantCredentials.normalized(config.token) else {
            return .error("Add a long-lived access token. In Home Assistant: your profile ▸ Security ▸ Long-lived access tokens.")
        }

        do {
            if settings.homeMode == .camera {
                guard let entity = settings.homeTarget, !entity.isEmpty else {
                    return .error("Pick a camera in the panel's settings.")
                }
                let image = try await cameraImage(base: base, token: token, entity: entity)
                return .image(image)
            }

            let states = try await states(base: base, token: token)
            let areas = (try? await areaLookup(base: base, token: token)) ?? [:]
            let unitIsFahrenheit = (try? await usesFahrenheit(base: base, token: token)) ?? false

            if settings.homeMode.isThermostat {
                guard var readout = thermostat(from: states, areas: areas,
                                               target: settings.homeTarget,
                                               fahrenheit: unitIsFahrenheit) else {
                    return .error(settings.homeTarget.map {
                        "No climate entity called “\($0)”. Pick one in the panel's settings."
                    } ?? "No climate entities on this Home Assistant. Pick one in the panel's settings.")
                }
                if settings.showsHomeRoomStrip {
                    readout.rooms = readings(from: states, areas: areas,
                                             kinds: [.temperature], rooms: [],
                                             fahrenheit: unitIsFahrenheit)
                }
                await attachHistory(to: &readout, settings: settings,
                                    base: base, token: token,
                                    fahrenheit: unitIsFahrenheit)
                return .thermostat(readout)
            }

            var found = readings(from: states, areas: areas,
                                 kinds: Set(settings.resolvedSensorKinds),
                                 rooms: Set(settings.homeRooms),
                                 fahrenheit: unitIsFahrenheit)
            if settings.homeMode == .rooms {
                found = found.filter { $0.kind == .temperature || $0.kind == .humidity }
            }
            guard !found.isEmpty else {
                return .error("Nothing matched. Check the sensor kinds and rooms the panel is set to.")
            }
            return .homeSensors(HomeSensorReport(homeName: nil, readings: found,
                                                 sourceLabel: "Home Assistant"))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Climate entities and cameras, for the settings pickers.
    public static func choices(mode: HomePanelMode, config: ConnectorConfig) async throws -> [HomeDeviceChoice] {
        guard let base = HomeAssistantCredentials.normalizedURL(config.projectURL),
              let token = HomeAssistantCredentials.normalized(config.token) else { return [] }
        let states = try await states(base: base, token: token)
        let areas = (try? await areaLookup(base: base, token: token)) ?? [:]
        let domain = mode == .camera ? "camera" : "climate"
        return states.compactMap { state -> HomeDeviceChoice? in
            guard let entity = state["entity_id"]?.stringValue,
                  entity.hasPrefix(domain + ".") else { return nil }
            return HomeDeviceChoice(id: entity,
                                    name: state["attributes"]?["friendly_name"]?.stringValue ?? entity,
                                    room: areas[entity],
                                    detail: mode == .camera ? "Camera" : "Thermostat")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Sensors

    static func readings(from states: [JSONValue],
                         areas: [String: String],
                         kinds: Set<HomeSensorKind>,
                         rooms: Set<String>,
                         fahrenheit: Bool) -> [HomeReading] {
        states.compactMap { state -> HomeReading? in
            guard let entity = state["entity_id"]?.stringValue else { return nil }
            guard let kind = kind(for: entity, attributes: state["attributes"]),
                  kinds.contains(kind) else { return nil }
            let room = areas[entity]
            if !rooms.isEmpty, room.map({ !rooms.contains($0) }) ?? true { return nil }

            let raw = state["state"]?.stringValue ?? ""
            // Home Assistant reports these two for anything it cannot reach.
            let isReachable = raw != "unavailable" && raw != "unknown"
            let attributes = state["attributes"]
            let name = attributes?["friendly_name"]?.stringValue ?? entity

            var reading = HomeReading(id: entity, name: name, room: room, kind: kind,
                                      updatedAt: date(state["last_updated"] ?? state["last_changed"]),
                                      isReachable: isReachable)
            if kind.isBinary {
                reading.isActive = isReachable ? isActive(kind: kind, state: raw) : nil
                if !isReachable { reading.text = "Unavailable" }
            } else if let value = Double(raw), isReachable {
                let unit = attributes?["unit_of_measurement"]?.stringValue
                reading.value = normalize(value, kind: kind, unit: unit, fahrenheit: fahrenheit)
            } else if isReachable {
                reading.text = raw.capitalized
            } else {
                reading.text = "Unavailable"
            }
            return reading
        }
    }

    /// Home Assistant's own classification, which is far more reliable than
    /// guessing from the entity's name — a `sensor.office` could be anything,
    /// but a `device_class` of `temperature` never is.
    static func kind(for entity: String, attributes: JSONValue?) -> HomeSensorKind? {
        let domain = entity.split(separator: ".").first.map(String.init) ?? ""
        let deviceClass = attributes?["device_class"]?.stringValue ?? ""

        if domain == "lock" { return .lock }
        if domain == "binary_sensor" {
            switch deviceClass {
            case "motion", "moving": return .motion
            case "occupancy", "presence": return .occupancy
            case "door", "window", "opening", "garage_door": return .contact
            case "smoke": return .smoke
            case "gas", "carbon_monoxide": return .carbonMonoxide
            case "moisture": return .leak
            case "battery": return .battery
            default: return nil
            }
        }
        guard domain == "sensor" else { return nil }
        switch deviceClass {
        case "temperature": return .temperature
        case "humidity": return .humidity
        case "illuminance": return .light
        case "carbon_dioxide": return .carbonDioxide
        case "volatile_organic_compounds", "volatile_organic_compounds_parts":
            return .volatileOrganic
        case "pm25": return .particulate
        case "aqi": return .airQuality
        case "battery": return .battery
        case "power": return .power
        case "energy": return .energy
        default: return nil
        }
    }

    static func isActive(kind: HomeSensorKind, state: String) -> Bool {
        switch kind {
        case .lock:
            // A lock that is jammed, opening or unknown is not locked, and
            // saying so is the useful behaviour.
            return state != "locked"
        default:
            return state == "on"
        }
    }

    /// Everything is stored in the canonical unit so a board synced between a
    /// Fahrenheit device and a Celsius one reads correctly on both.
    static func normalize(_ value: Double, kind: HomeSensorKind,
                          unit: String?, fahrenheit: Bool) -> Double {
        switch kind {
        case .temperature:
            // The sensor's own unit wins; the server default only applies
            // when the entity declines to say.
            let isF = unit.map { $0.contains("F") } ?? fahrenheit
            return isF ? (value - 32) * 5 / 9 : value
        case .power:
            return unit?.lowercased() == "kw" ? value * 1000 : value
        case .energy:
            switch unit?.lowercased() {
            case "wh": return value / 1000
            case "mwh": return value * 1000
            default: return value
            }
        default:
            return value
        }
    }

    // MARK: - Thermostat

    static func thermostat(from states: [JSONValue],
                           areas: [String: String],
                           target: String?,
                           fahrenheit: Bool) -> ThermostatReadout? {
        let climates = states.filter {
            ($0["entity_id"]?.stringValue ?? "").hasPrefix("climate.")
        }
        let state: JSONValue?
        if let target, !target.isEmpty {
            state = climates.first { $0["entity_id"]?.stringValue == target }
        } else {
            state = climates.first
        }
        guard let state, let entity = state["entity_id"]?.stringValue else { return nil }
        let attributes = state["attributes"]
        let raw = state["state"]?.stringValue ?? ""

        func temperature(_ key: String) -> Double? {
            attributes?[key]?.doubleValue.map { fahrenheit ? ($0 - 32) * 5 / 9 : $0 }
        }

        var readout = ThermostatReadout(
            id: entity,
            name: attributes?["friendly_name"]?.stringValue ?? entity,
            room: areas[entity],
            currentC: temperature("current_temperature"),
            humidity: attributes?["current_humidity"]?.doubleValue,
            targetC: temperature("temperature"),
            heatSetpointC: temperature("target_temp_low"),
            coolSetpointC: temperature("target_temp_high"),
            mode: mode(from: raw),
            status: status(from: attributes?["hvac_action"]?.stringValue, mode: raw),
            isOnline: raw != "unavailable" && raw != "unknown",
            sourceLabel: "Home Assistant",
            updatedAt: date(state["last_updated"] ?? state["last_changed"]))

        if let fan = attributes?["fan_mode"]?.stringValue {
            readout.fanIsOn = fan.lowercased() != "off" && fan.lowercased() != "auto"
        }
        if let preset = attributes?["preset_mode"]?.stringValue,
           !preset.isEmpty, preset.lowercased() != "none" {
            readout.holdLabel = preset.capitalized
        }
        return readout
    }

    static func mode(from raw: String) -> ThermostatMode {
        switch raw {
        case "off": return .off
        case "heat": return .heat
        case "cool": return .cool
        case "heat_cool", "auto": return .auto
        case "dry": return .dry
        case "fan_only": return .fanOnly
        default: return .unknown
        }
    }

    /// `hvac_action` is what the equipment is doing; the entity's state is
    /// only what it was asked to do. Not every integration reports the
    /// action, so a thermostat that says "heat" and nothing else falls back
    /// to `.unknown` rather than being counted as a run that never happened.
    static func status(from action: String?, mode: String) -> HVACStatus {
        switch action {
        case "heating", "preheating", "defrosting": return .heating
        case "cooling", "drying": return .cooling
        case "fan": return .fan
        case "idle", "off": return .off
        default:
            return mode == "off" ? .off : .unknown
        }
    }

    // MARK: - History

    /// Records the current sample, and — only on a panel that has almost no
    /// history of its own — asks Home Assistant's recorder for the rest.
    ///
    /// This is the one provider that can fill in the past, and it matters:
    /// without it a new trend panel is a blank chart for half a day.
    static func attachHistory(to readout: inout ThermostatReadout,
                              settings: PanelSettings,
                              base: String, token: String,
                              fahrenheit: Bool) async {
        let key = HomeReadout.historyKey(for: readout)
        if await HVACHistoryStore.shared.needsBackfill(for: key),
           let past = try? await history(base: base, token: token,
                                         entity: readout.id,
                                         hours: settings.resolvedTrendHours,
                                         fahrenheit: fahrenheit) {
            await HVACHistoryStore.shared.backfill(past, for: key)
        }
        await HomeReadout.attachHistory(to: &readout, settings: settings)
    }

    /// Parses `/api/history/period`, which answers with an array *per entity*
    /// of state changes, each carrying the attributes as they were.
    static func history(base: String, token: String, entity: String,
                        hours: Double, fahrenheit: Bool,
                        now: Date = Date()) async throws -> [HVACSample] {
        let start = now.addingTimeInterval(-hours * 3600)
        let formatter = ISO8601DateFormatter()
        let path = "/api/history/period/\(formatter.string(from: start))"
        var items = URLComponents()
        items.queryItems = [
            URLQueryItem(name: "filter_entity_id", value: entity),
            // Attributes are exactly what is wanted here — the temperature
            // and the HVAC action live there, not in the state string — so
            // `minimal_response` and `no_attributes` must both stay off.
            URLQueryItem(name: "significant_changes_only", value: "0"),
        ]
        let query = items.percentEncodedQuery.map { "?\($0)" } ?? ""
        let json = try await request(base: base, path: path + query, token: token)
        return (json.arrayValue?.first?.arrayValue ?? []).compactMap { entry in
            guard let stamp = date(entry["last_updated"] ?? entry["last_changed"]) else {
                return nil
            }
            let attributes = entry["attributes"]
            let raw = entry["state"]?.stringValue ?? ""
            func temperature(_ key: String) -> Double? {
                attributes?[key]?.doubleValue.map { fahrenheit ? ($0 - 32) * 5 / 9 : $0 }
            }
            return HVACSample(date: stamp,
                              indoorC: temperature("current_temperature"),
                              targetC: temperature("temperature"),
                              humidity: attributes?["current_humidity"]?.doubleValue,
                              status: status(from: attributes?["hvac_action"]?.stringValue,
                                             mode: raw))
        }
    }

    // MARK: - Requests

    static func states(base: String, token: String) async throws -> [JSONValue] {
        try await request(base: base, path: "/api/states", token: token).arrayValue ?? []
    }

    /// Areas — Home Assistant's word for rooms — are not in the REST state
    /// list at all; they live in the registry, which only the WebSocket API
    /// exposes. Rendering a template is the way to reach them over REST, and
    /// it costs one request for the whole house.
    static func areaLookup(base: String, token: String) async throws -> [String: String] {
        let template = """
        {%- set ns = namespace(rows=[]) -%}
        {%- for area in areas() -%}
        {%- for entity in area_entities(area) -%}
        {%- set ns.rows = ns.rows + [entity ~ '\\t' ~ area_name(area)] -%}
        {%- endfor -%}
        {%- endfor -%}
        {{ ns.rows | join('\\n') }}
        """
        guard let url = URL(string: base + "/api/template") else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["template": template])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            // Rooms are a nicety; a server with templates disabled should
            // still get its sensors, just ungrouped.
            return [:]
        }
        var lookup: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            lookup[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return lookup
    }

    /// The server's own temperature unit, for climate entities — those
    /// report in the system unit and, unlike sensors, carry no unit of their
    /// own to check.
    static func usesFahrenheit(base: String, token: String) async throws -> Bool {
        let json = try await request(base: base, path: "/api/config", token: token)
        let unit = json["unit_system"]?["temperature"]?.stringValue ?? "°C"
        return unit.contains("F")
    }

    static func cameraImage(base: String, token: String, entity: String) async throws -> Data {
        guard let url = URL(string: base + "/api/camera_proxy/" + entity) else {
            throw SBError.message("Invalid camera entity")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, base: base)
        guard !data.isEmpty else {
            throw SBError.message("Home Assistant returned an empty frame for \(entity)")
        }
        return data
    }

    static func request(base: String, path: String, token: String) async throws -> JSONValue {
        guard let url = URL(string: base + path) else {
            throw SBError.message("Invalid Home Assistant address")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, base: base)
        return try JSONValue.parse(data)
    }

    private static func check(_ response: URLResponse, base: String) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401:
            throw SBError.message("Home Assistant rejected the token. Create a new long-lived access token in your profile ▸ Security.")
        case 403:
            throw SBError.message("That token isn't allowed to read this. Check the user's permissions in Home Assistant.")
        case 404:
            throw SBError.message("Not found on \(base) — check the address, and that the entity still exists.")
        default:
            throw SBError.message("Home Assistant HTTP \(http.statusCode)")
        }
    }

    /// Home Assistant stamps times with fractional seconds and an offset,
    /// which the plain formatter refuses.
    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
