import Foundation

/// Reads a weather station the user owns.
///
/// There is no standard for this, so the source is shape-agnostic: it walks a
/// handful of known payload layouts (Ecowitt/Ambient, WeeWX, Home Assistant,
/// WeatherFlow), and failing that hunts the JSON for keys that look like a
/// temperature. A user whose station is stranger than all of that can type
/// exact dot paths instead.
public enum PersonalWeatherSource {
    public struct Reading: Sendable {
        public var temperatureC: Double
        public var windKPH: Double?
        public var humidity: Double?
        public var conditionText: String?
        public var stationName: String?
    }

    public enum PWSError: LocalizedError {
        case noURL
        case noTemperature(String)

        public var errorDescription: String? {
            switch self {
            case .noURL:
                return "Set your weather station's address"
            case .noTemperature(let detail):
                return "No temperature in the station's reply. \(detail)"
            }
        }
    }

    public static func fetch(settings: PanelSettings) async throws -> Reading {
        guard let urlString = settings.weatherPersonalURL?.trimmingCharacters(in: .whitespaces),
              !urlString.isEmpty, let url = URL(string: urlString) else {
            throw PWSError.noURL
        }
        let data = try await WebQuerySource.fetch(url: url)
        let json = try JSONValue.parse(data)
        return try reading(from: json, settings: settings)
    }

    /// Split out from the fetch so the parsing is unit-testable without a
    /// station on the network.
    public static func reading(from json: JSONValue,
                               settings: PanelSettings) throws -> Reading {
        let format = settings.weatherPersonalFormat
        let paths = settings.weatherPersonalPaths

        /// The reading *and* the key it came from — the units are encoded in
        /// the name (`tempf` is Fahrenheit, `outTemp_C` is Celsius), so the two
        /// have to travel together. Reading them separately is how an explicit
        /// path can end up converted by some other field's units.
        func value(_ field: PersonalWeatherField) -> (value: JSONValue, key: String)? {
            if let path = paths[field.rawValue], !path.isEmpty {
                return JSONPath.first(path, in: json).map { ($0, path) }
            }
            guard format != .custom else { return nil }
            for key in candidateKeys(field, format: format) {
                if let found = JSONPath.first(key, in: json) { return (found, key) }
            }
            // Nothing matched a known name, so search the whole document for a
            // key that looks right — stations nest their readings differently
            // and there is no point in guessing at container names.
            let names = candidateLeafNames(field)
            guard let found = deepSearch(json, names: names) else { return nil }
            return (found, deepSearchKey(json, names: names) ?? "")
        }

        guard let temperatureMatch = value(.temperature),
              let rawTemperature = temperatureMatch.value.doubleValue else {
            throw PWSError.noTemperature(
                "Tried \(candidateKeys(.temperature, format: format).prefix(4).joined(separator: ", ")). "
                + "Set the JSON path by hand if your station uses another name.")
        }
        let temperature = celsius(rawTemperature, key: temperatureMatch.key)
        let wind = value(.wind)
        var windKPH = wind?.value.doubleValue
        if let speed = windKPH, isMPH(wind?.key) {
            windKPH = speed * 1.609344
        }
        return Reading(temperatureC: temperature,
                       windKPH: windKPH,
                       humidity: value(.humidity)?.value.doubleValue,
                       conditionText: value(.condition)?.value.stringValue,
                       stationName: JSONPath.first("stationtype", in: json)?.stringValue
                           ?? JSONPath.first("attributes.friendly_name", in: json)?.stringValue)
    }

    // MARK: - Shapes

    static func candidateKeys(_ field: PersonalWeatherField,
                              format: PersonalWeatherFormat) -> [String] {
        switch (field, format) {
        case (.temperature, .ecowitt):
            return ["data.outdoor.temperature.value", "outdoor.temperature.value", "tempf"]
        case (.temperature, .weewx):
            return ["current.outTemp_C", "current.outTemp_F", "outTemp_C", "outTemp_F", "outTemp"]
        case (.temperature, .homeAssistant):
            return ["attributes.temperature", "state"]
        case (.temperature, .weatherflow):
            return ["obs[0].air_temperature", "air_temperature", "obs[0][7]"]
        case (.wind, .ecowitt):
            return ["data.wind.wind_speed.value", "wind.wind_speed.value", "windspeedmph"]
        case (.wind, .weewx):
            return ["current.windSpeed_kph", "current.windSpeed", "windSpeed"]
        case (.wind, .homeAssistant):
            return ["attributes.wind_speed"]
        case (.wind, .weatherflow):
            return ["obs[0].wind_avg", "wind_avg"]
        case (.humidity, .ecowitt):
            return ["data.outdoor.humidity.value", "outdoor.humidity.value", "humidity"]
        case (.humidity, .weewx):
            return ["current.outHumidity", "outHumidity"]
        case (.humidity, .homeAssistant):
            return ["attributes.humidity"]
        case (.humidity, .weatherflow):
            return ["obs[0].relative_humidity", "relative_humidity"]
        case (.condition, .homeAssistant):
            return ["state"]
        default:
            return field.candidateKeys
        }
    }

    /// The leaf key names to look for when walking an unknown payload.
    static func candidateLeafNames(_ field: PersonalWeatherField) -> [String] {
        switch field {
        case .temperature:
            return ["tempf", "temp_f", "outtemp_f", "outtemp_c", "temp_c", "outtemp",
                    "temperature", "air_temperature", "temperature_2m"]
        case .wind:
            return ["windspeedmph", "windspeed", "wind_speed", "wind_avg", "windspeed_kph"]
        case .humidity:
            return ["humidity", "outhumidity", "relative_humidity"]
        case .condition:
            return ["condition", "weather", "summary", "state", "text"]
        }
    }

    /// Depth-first hunt for a leaf whose key is one of `names`.
    static func deepSearch(_ json: JSONValue, names: [String], depth: Int = 0) -> JSONValue? {
        guard depth < 6, let object = json.objectValue else { return nil }
        for (key, value) in object where names.contains(key.lowercased()) {
            if value.doubleValue != nil || value.stringValue != nil { return value }
            // Ecowitt wraps each reading in {unit, value}.
            if let inner = value["value"], inner.doubleValue != nil { return inner }
        }
        for value in object.values {
            if let found = deepSearch(value, names: names, depth: depth + 1) { return found }
        }
        return nil
    }

    static func deepSearchKey(_ json: JSONValue, names: [String], depth: Int = 0) -> String? {
        guard depth < 6, let object = json.objectValue else { return nil }
        for (key, value) in object where names.contains(key.lowercased()) {
            if value.doubleValue != nil || value.stringValue != nil || value["value"] != nil {
                return key
            }
        }
        for value in object.values {
            if let found = deepSearchKey(value, names: names, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Units

    /// Stations name their fields after their units. Anything explicitly
    /// Fahrenheit is converted; anything else is assumed to already be Celsius,
    /// except a bare value above 60 — no outdoor station reads 60 °C.
    static func celsius(_ value: Double, key: String?) -> Double {
        let lowered = (key ?? "").lowercased()
        if lowered.hasSuffix("_c") || lowered.contains("temp_c") || lowered.contains("_c.") {
            return value
        }
        if lowered.contains("f") && (lowered.hasSuffix("f") || lowered.contains("_f")) {
            return (value - 32) * 5 / 9
        }
        return value > 60 ? (value - 32) * 5 / 9 : value
    }

    static func isMPH(_ key: String?) -> Bool {
        (key ?? "").lowercased().contains("mph")
    }
}
