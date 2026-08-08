import Foundation

/// How a weather panel decides *where* to report on.
public enum WeatherLocationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Latitude and longitude typed in directly — the original behaviour.
    case coordinates
    /// A city, postal code or street address, geocoded once and remembered.
    case place
    /// A named observation station, e.g. an airport's METAR/NWS identifier.
    case station
    /// The user's own weather station, read straight off their network.
    case personal
    /// Wherever this device is right now.
    case current

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .coordinates: return "Coordinates"
        case .place: return "City or Address"
        case .station: return "Weather Station"
        case .personal: return "My Weather Station"
        case .current: return "Current Location"
        }
    }

    public var symbolName: String {
        switch self {
        case .coordinates: return "number"
        case .place: return "magnifyingglass"
        case .station: return "antenna.radiowaves.left.and.right"
        case .personal: return "house"
        case .current: return "location.fill"
        }
    }
}

/// Networks whose public station observations Status Board can read without
/// an account or an API key.
public enum WeatherStationNetwork: String, Codable, CaseIterable, Sendable, Identifiable {
    /// US National Weather Service (api.weather.gov), station IDs like KSFO.
    case nws
    /// Any ICAO airport worldwide, via the NOAA aviation weather METAR feed.
    case metar

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nws: return "US National Weather Service"
        case .metar: return "Airport (METAR, worldwide)"
        }
    }

    public var hint: String {
        switch self {
        case .nws: return "A four-letter NWS station ID, e.g. KSFO or KJFK. Find yours at weather.gov."
        case .metar: return "An ICAO airport code, e.g. EGLL (Heathrow) or RJTT (Haneda)."
        }
    }
}

/// Payload shapes Status Board understands from a self-hosted station.
public enum PersonalWeatherFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Sniff the JSON and match whichever known shape it looks like.
    case automatic
    /// Ecowitt / Ambient Weather local API (`GW1000`, `WS-2902` and friends).
    case ecowitt
    /// WeeWX's JSON report.
    case weewx
    /// A Home Assistant `weather.*` entity read through its REST API.
    case homeAssistant
    /// WeatherFlow Tempest local UDP bridge / REST observation.
    case weatherflow
    /// Explicit dot paths typed in by the user.
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Detect Automatically"
        case .ecowitt: return "Ecowitt / Ambient Weather"
        case .weewx: return "WeeWX"
        case .homeAssistant: return "Home Assistant"
        case .weatherflow: return "WeatherFlow Tempest"
        case .custom: return "Custom JSON paths"
        }
    }
}

/// Fields a personal station can supply, used as keys into
/// `PanelSettings.weatherPersonalPaths`.
public enum PersonalWeatherField: String, CaseIterable, Sendable, Identifiable {
    case temperature
    case condition
    case wind
    case humidity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .temperature: return "Temperature"
        case .condition: return "Condition"
        case .wind: return "Wind speed"
        case .humidity: return "Humidity"
        }
    }

    /// Key names seen in the wild, tried in order when detecting automatically.
    /// Longest/most specific first so `tempf` doesn't shadow `tempinf`.
    public var candidateKeys: [String] {
        switch self {
        case .temperature:
            return ["outdoor.temperature.value", "temperature", "outTemp_F", "outTemp_C",
                    "outTemp", "tempf", "temp_c", "temp_f", "air_temperature",
                    "temperature_2m", "attributes.temperature", "current.temp_c"]
        case .condition:
            return ["condition", "state", "weather", "text", "summary",
                    "current.condition.text"]
        case .wind:
            return ["wind.speed.value", "windSpeed", "windspeedmph", "wind_avg",
                    "wind_speed", "windSpeed_kph", "attributes.wind_speed",
                    "current.wind_kph"]
        case .humidity:
            return ["outdoor.humidity.value", "humidity", "outHumidity", "humidityin",
                    "relative_humidity", "attributes.humidity"]
        }
    }
}

/// Which units a weather panel shows. `automatic` follows the device's locale,
/// which is what every build before this shipped.
public enum WeatherUnits: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    case celsius
    case fahrenheit

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .celsius: return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }

    /// The concrete unit every part of a weather panel must use. Resolving
    /// `.automatic` once prevents the headline's Foundation formatter and the
    /// hand-formatted forecast cells from making different choices.
    public func resolved(for locale: Locale = .current) -> WeatherUnits {
        guard self == .automatic else { return self }
        return locale.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

/// How forecast days are arranged inside a weather panel.
public enum WeatherForecastLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    /// Days run left to right, best for wide and short panels.
    case horizontal
    /// One day per row, best for tall or narrow panels.
    case vertical

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .horizontal: return "Across"
        case .vertical: return "Down"
        }
    }

    /// Resolves the automatic choice without SwiftUI so it is testable and is
    /// shared by the app, WidgetKit, and every target shape.
    public func resolved(width: Double, height: Double) -> WeatherForecastLayout {
        guard self == .automatic else { return self }
        return width >= height ? .horizontal : .vertical
    }
}

/// One candidate answer to a place search, offered to the user to pick from.
public struct GeocodedPlace: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(name)|\(latitude),\(longitude)" }
    public var name: String
    /// "Ithaca, New York, United States" — enough to tell duplicates apart.
    public var detail: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, detail: String, latitude: Double, longitude: Double) {
        self.name = name
        self.detail = detail
        self.latitude = latitude
        self.longitude = longitude
    }
}

extension PanelSettings {
    /// Whether this panel already knows where to look, or still needs the
    /// location resolving before the forecast can be fetched.
    public var hasResolvedWeatherCoordinates: Bool {
        latitude != nil && longitude != nil
    }

    /// A short description of the configured location for the inspector.
    public var weatherLocationSummary: String {
        switch weatherLocationMode {
        case .coordinates:
            guard let latitude, let longitude else { return "Not set" }
            return String(format: "%.4f, %.4f", latitude, longitude)
        case .place:
            return locationName ?? weatherPlaceQuery ?? "Not set"
        case .station:
            guard let id = weatherStationID, !id.isEmpty else { return "Not set" }
            return locationName.map { "\(id) — \($0)" } ?? id
        case .personal:
            guard let url = weatherPersonalURL, !url.isEmpty else { return "Not set" }
            return locationName ?? url
        case .current:
            return locationName ?? "This device"
        }
    }
}
