import Foundation

/// Weather via the free Open-Meteo API — no API key required.
///
/// The panel says *where* in one of five ways (coordinates, a place name, a
/// public station, the user's own station, or this device's location); every
/// one of them ends up as a latitude and longitude, which is all the forecast
/// needs. Observations from a station replace the "right now" numbers while
/// the day strip still comes from the forecast.
public enum WeatherSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        do {
            let resolved = try await resolveLocation(settings: settings)
            var report = try await forecast(latitude: resolved.latitude,
                                            longitude: resolved.longitude,
                                            name: resolved.name)
            if let observation = resolved.observation {
                report = merge(observation, into: report)
            }
            return .weather(report)
        } catch let error as LocalizedError {
            return .error(error.errorDescription ?? error.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Location

    /// Where to report on, plus a station observation when the panel is
    /// pointed at one.
    struct ResolvedLocation {
        var latitude: Double
        var longitude: Double
        var name: String
        var observation: Observation?
    }

    /// Current conditions from something other than the forecast.
    struct Observation {
        var temperatureC: Double
        var windKPH: Double?
        var humidity: Double?
        var conditionText: String?
        var code: Int?
        var sourceLabel: String
        var observedAt: Date?
    }

    enum WeatherError: LocalizedError {
        case noLocation

        var errorDescription: String? {
            "Set a location in the panel settings"
        }
    }

    static func resolveLocation(settings: PanelSettings) async throws -> ResolvedLocation {
        switch settings.weatherLocationMode {
        case .coordinates:
            guard let latitude = settings.latitude, let longitude = settings.longitude else {
                throw WeatherError.noLocation
            }
            return ResolvedLocation(latitude: latitude, longitude: longitude,
                                    name: settings.locationName ?? "Weather")

        case .place:
            guard let query = settings.weatherPlaceQuery?.trimmingCharacters(in: .whitespaces),
                  !query.isEmpty else {
                // The panel was switched to Place but nothing typed yet; fall
                // back to whatever coordinates it already had.
                guard let latitude = settings.latitude, let longitude = settings.longitude else {
                    throw WeatherError.noLocation
                }
                return ResolvedLocation(latitude: latitude, longitude: longitude,
                                        name: settings.locationName ?? "Weather")
            }
            if let place = await WeatherLocationCache.resolve(query) {
                return ResolvedLocation(latitude: place.latitude, longitude: place.longitude,
                                        name: settings.locationName ?? place.name)
            }
            // Geocoding is down or the name is unknown. Coordinates saved when
            // the place was first picked keep the panel alive.
            guard let latitude = settings.latitude, let longitude = settings.longitude else {
                throw WeatherError.noLocation
            }
            return ResolvedLocation(latitude: latitude, longitude: longitude,
                                    name: settings.locationName ?? query)

        case .station:
            guard let id = settings.weatherStationID?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty else { throw WeatherError.noLocation }
            let reading = try await StationWeatherSource.fetch(
                id: id, network: settings.weatherStationNetwork)
            // A station without coordinates still gives conditions; the day
            // strip then comes from whatever the panel had configured.
            let latitude = reading.latitude ?? settings.latitude
            let longitude = reading.longitude ?? settings.longitude
            guard let latitude, let longitude else { throw WeatherError.noLocation }
            return ResolvedLocation(
                latitude: latitude, longitude: longitude,
                name: settings.locationName ?? reading.stationName,
                observation: Observation(temperatureC: reading.temperatureC,
                                         windKPH: reading.windKPH,
                                         humidity: reading.humidity,
                                         conditionText: reading.conditionText,
                                         code: reading.code,
                                         sourceLabel: id.uppercased(),
                                         observedAt: reading.observedAt))

        case .personal:
            let reading = try await PersonalWeatherSource.fetch(settings: settings)
            // A personal station reports conditions, not a forecast, so the
            // day strip needs coordinates from wherever the panel got them.
            let latitude = settings.latitude ?? 0
            let longitude = settings.longitude ?? 0
            return ResolvedLocation(
                latitude: latitude, longitude: longitude,
                name: settings.locationName ?? reading.stationName ?? "My Station",
                observation: Observation(temperatureC: reading.temperatureC,
                                         windKPH: reading.windKPH,
                                         humidity: reading.humidity,
                                         conditionText: reading.conditionText,
                                         code: reading.conditionText.map(StationWeatherSource.code(forText:)),
                                         sourceLabel: "My station",
                                         observedAt: Date()))

        case .current:
            do {
                let place = try await WeatherLocationProvider.shared.currentPlace()
                return ResolvedLocation(latitude: place.latitude, longitude: place.longitude,
                                        name: place.name)
            } catch {
                // Location can be off, denied, or simply not ready. The last
                // known position beats an empty panel.
                if let remembered = WeatherLocationProvider.lastKnown {
                    return ResolvedLocation(latitude: remembered.latitude,
                                            longitude: remembered.longitude,
                                            name: remembered.name)
                }
                throw error
            }
        }
    }

    /// Folds a station's live numbers over the forecast's.
    static func merge(_ observation: Observation, into report: WeatherReport) -> WeatherReport {
        var merged = report
        merged.temperatureC = observation.temperatureC
        if let wind = observation.windKPH { merged.windKPH = wind }
        if let humidity = observation.humidity { merged.humidity = humidity }
        if let code = observation.code {
            merged.code = code
            merged.symbolName = symbol(for: code, isDaytime: report.isDaytime)
        }
        if let text = observation.conditionText, !text.isEmpty, text != "—" {
            merged.conditionDescription = text
        }
        merged.sourceLabel = observation.sourceLabel
        merged.observedAt = observation.observedAt
        return merged
    }

    // MARK: - Forecast

    static func forecast(latitude: Double, longitude: Double,
                         name: String) async throws -> WeatherReport {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current",
                         value: "temperature_2m,relative_humidity_2m,apparent_temperature,"
                             + "is_day,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
            URLQueryItem(name: "forecast_days", value: "5"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let data = try await WebQuerySource.fetch(url: components.url!)
        let json = try JSONValue.parse(data)
        guard let current = json["current"],
              let temperature = current["temperature_2m"]?.doubleValue else {
            throw SBError.message("Unexpected weather response")
        }
        let code = Int(current["weather_code"]?.doubleValue ?? -1)
        let wind = current["wind_speed_10m"]?.doubleValue ?? 0
        // `is_day` is 1 or 0 in the forecast's *local* time, which is exactly
        // the question the animated sky needs answered.
        let isDaytime = (current["is_day"]?.doubleValue ?? 1) > 0

        var days: [WeatherReport.Day] = []
        if let dates = json["daily"]?["time"]?.arrayValue,
           let highs = json["daily"]?["temperature_2m_max"]?.arrayValue,
           let lows = json["daily"]?["temperature_2m_min"]?.arrayValue,
           let codes = json["daily"]?["weather_code"]?.arrayValue {
            for index in dates.indices {
                guard let high = highs[safe: index]?.doubleValue,
                      let low = lows[safe: index]?.doubleValue else { continue }
                let dayCode = Int(codes[safe: index]?.doubleValue ?? -1)
                days.append(WeatherReport.Day(
                    dateLabel: shortWeekday(from: dates[safe: index]?.stringValue),
                    highC: high, lowC: low,
                    symbolName: symbol(for: dayCode)))
            }
        }

        return WeatherReport(
            locationName: name,
            temperatureC: temperature,
            symbolName: symbol(for: code, isDaytime: isDaytime),
            conditionDescription: condition(for: code),
            windKPH: wind,
            days: days,
            code: code,
            isDaytime: isDaytime,
            humidity: current["relative_humidity_2m"]?.doubleValue,
            feelsLikeC: current["apparent_temperature"]?.doubleValue,
            sourceLabel: "Open-Meteo")
    }

    static func shortWeekday(from isoDay: String?) -> String {
        guard let isoDay,
              let date = try? Date(isoDay + "T12:00:00Z", strategy: .iso8601) else { return "—" }
        return date.formatted(Date.FormatStyle().weekday(.abbreviated))
    }

    /// WMO weather code → SF Symbol. At night the clear and partly-cloudy
    /// symbols get their moon variants, which is what makes a weather panel
    /// look right on a board someone glances at after dark.
    public static func symbol(for code: Int, isDaytime: Bool = true) -> String {
        switch code {
        case 0: return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }

    public static func condition(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow Showers"
        case 95...99: return "Thunderstorms"
        default: return "—"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
