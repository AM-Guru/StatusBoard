import Foundation

/// Weather via the free Open-Meteo API — no API key required.
public enum WeatherSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let latitude = settings.latitude, let longitude = settings.longitude else {
            return .error("Set a location in the panel settings")
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code"),
            URLQueryItem(name: "forecast_days", value: "5"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        do {
            let data = try await WebQuerySource.fetch(url: components.url!)
            let json = try JSONValue.parse(data)
            guard let current = json["current"],
                  let temperature = current["temperature_2m"]?.doubleValue else {
                return .error("Unexpected weather response")
            }
            let code = Int(current["weather_code"]?.doubleValue ?? -1)
            let wind = current["wind_speed_10m"]?.doubleValue ?? 0

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

            let report = WeatherReport(
                locationName: settings.locationName ?? "Weather",
                temperatureC: temperature,
                symbolName: symbol(for: code),
                conditionDescription: condition(for: code),
                windKPH: wind,
                days: days)
            return .weather(report)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func shortWeekday(from isoDay: String?) -> String {
        guard let isoDay,
              let date = try? Date(isoDay + "T12:00:00Z", strategy: .iso8601) else { return "—" }
        return date.formatted(Date.FormatStyle().weekday(.abbreviated))
    }

    /// WMO weather code → SF Symbol.
    public static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
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
