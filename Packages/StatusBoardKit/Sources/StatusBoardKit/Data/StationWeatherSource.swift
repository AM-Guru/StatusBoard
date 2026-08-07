import Foundation

/// Current conditions straight from a named observation station.
///
/// Both networks here are public and keyless. What comes back is an
/// *observation*, not a forecast — so `WeatherSource` pairs it with an
/// Open-Meteo forecast at the station's own coordinates to fill the day strip.
public enum StationWeatherSource {
    public struct Observation: Sendable {
        public var temperatureC: Double
        public var windKPH: Double
        public var humidity: Double?
        public var conditionText: String
        /// Best-effort WMO code, so a station drives the same animated skies
        /// every other source does.
        public var code: Int
        public var stationName: String
        public var latitude: Double?
        public var longitude: Double?
        public var observedAt: Date?
    }

    public enum StationError: LocalizedError {
        case notFound(String)
        case noObservation(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id):
                return "No station called \(id). Check the identifier and the network."
            case .noObservation(let id):
                return "Station \(id) has not reported recently"
            }
        }
    }

    public static func fetch(id rawID: String,
                             network: WeatherStationNetwork) async throws -> Observation {
        let id = rawID.trimmingCharacters(in: .whitespaces).uppercased()
        guard !id.isEmpty else { throw StationError.notFound(rawID) }
        switch network {
        case .nws: return try await fetchNWS(id: id)
        case .metar: return try await fetchMETAR(id: id)
        }
    }

    // MARK: - National Weather Service

    static func fetchNWS(id: String) async throws -> Observation {
        // api.weather.gov requires a User-Agent identifying the caller, and
        // returns 403 without one.
        let latest = try await getJSON("https://api.weather.gov/stations/\(id)/observations/latest")
        guard let properties = latest["properties"] else { throw StationError.noObservation(id) }
        guard let temperature = properties["temperature"]?["value"]?.doubleValue else {
            throw StationError.noObservation(id)
        }
        // NWS reports wind in m/s and gives null for anything the sensor missed.
        let wind = (properties["windSpeed"]?["value"]?.doubleValue).map { $0 * 3.6 } ?? 0
        let humidity = properties["relativeHumidity"]?["value"]?.doubleValue
        let text = properties["textDescription"]?.stringValue ?? "—"
        var latitude: Double?
        var longitude: Double?
        var name = id
        if let station = try? await getJSON("https://api.weather.gov/stations/\(id)") {
            name = station["properties"]?["name"]?.stringValue ?? id
            if let coordinates = station["geometry"]?["coordinates"]?.arrayValue,
               coordinates.count >= 2 {
                longitude = coordinates[0].doubleValue
                latitude = coordinates[1].doubleValue
            }
        }
        return Observation(temperatureC: temperature, windKPH: wind, humidity: humidity,
                           conditionText: text, code: code(forText: text),
                           stationName: name, latitude: latitude, longitude: longitude,
                           observedAt: properties["timestamp"]?.stringValue
                               .flatMap { try? Date($0, strategy: .iso8601) })
    }

    // MARK: - METAR (any ICAO airport)

    static func fetchMETAR(id: String) async throws -> Observation {
        let json = try await getJSON(
            "https://aviationweather.gov/api/data/metar?ids=\(id)&format=json")
        // The endpoint answers with an array, empty when the code is unknown.
        guard let report = json.arrayValue?.first else { throw StationError.notFound(id) }
        guard let temperature = report["temp"]?.doubleValue else {
            throw StationError.noObservation(id)
        }
        // Wind is in knots.
        let wind = (report["wspd"]?.doubleValue ?? 0) * 1.852
        let dewpoint = report["dewp"]?.doubleValue
        let text = report["wxString"]?.stringValue
            ?? cloudDescription(report["clouds"]?.arrayValue)
        return Observation(temperatureC: temperature, windKPH: wind,
                           humidity: dewpoint.map { relativeHumidity(temperature: temperature,
                                                                    dewPoint: $0) },
                           conditionText: text, code: code(forText: text),
                           stationName: report["name"]?.stringValue ?? id,
                           latitude: report["lat"]?.doubleValue,
                           longitude: report["lon"]?.doubleValue,
                           observedAt: report["reportTime"]?.stringValue
                               .flatMap { Self.metarDate($0) })
    }

    /// METAR cloud layers → "Clear", "Few clouds", "Overcast".
    static func cloudDescription(_ layers: [JSONValue]?) -> String {
        guard let layers, !layers.isEmpty else { return "Clear" }
        let covers = layers.compactMap { $0["cover"]?.stringValue }
        if covers.contains("OVC") { return "Overcast" }
        if covers.contains("BKN") { return "Mostly Cloudy" }
        if covers.contains("SCT") { return "Partly Cloudy" }
        if covers.contains("FEW") { return "Few Clouds" }
        return "Clear"
    }

    /// August–Roche–Magnus, accurate to a fraction of a percent over the range
    /// a weather station sees.
    static func relativeHumidity(temperature: Double, dewPoint: Double) -> Double {
        let numerator = exp((17.625 * dewPoint) / (243.04 + dewPoint))
        let denominator = exp((17.625 * temperature) / (243.04 + temperature))
        return min(100, max(0, 100 * numerator / denominator))
    }

    static func metarDate(_ text: String) -> Date? {
        if let iso = try? Date(text, strategy: .iso8601) { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)
    }

    // MARK: - Shared

    static func getJSON(_ urlString: String) async throws -> JSONValue {
        guard let url = URL(string: urlString) else { throw SBError.message("Bad station URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Both services ask callers to identify themselves; NWS rejects the
        // request outright without it.
        request.setValue("StatusBoard/1.0 (status board app; contact via App Store)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json,application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SBError.http(http.statusCode)
        }
        return try JSONValue.parse(data)
    }

    /// Free-text conditions → the WMO code the rest of the app speaks, so the
    /// symbol and the animated sky match what a station reports.
    public static func code(forText text: String) -> Int {
        let lowered = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { lowered.contains($0) } }
        if has("thunder", "tstm", "squall") { return 95 }
        if has("snow", "sleet", "ice pellets", "flurr") { return 73 }
        if has("freezing") { return 66 }
        if has("shower") { return 80 }
        // Mist is a fog phenomenon, and stations write "Fog/Mist" — so it has
        // to be tested before anything that would claim it as light rain.
        if has("fog", "mist", "haze", "smoke") { return 45 }
        if has("drizzle") { return 53 }
        if has("rain") { return 63 }
        if has("overcast") { return 3 }
        if has("mostly cloudy", "broken", "partly", "few clouds", "scattered") { return 2 }
        if has("clear", "fair", "sunny", "skc", "clr") { return 0 }
        return 2
    }
}
