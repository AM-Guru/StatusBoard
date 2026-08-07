import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// Turns what a person types — "Ithaca", "1 Infinite Loop, Cupertino", "SW1A
/// 1AA" — into coordinates.
///
/// Two lookups, in order: Apple's on-device geocoder handles street addresses
/// and postal codes and needs no key or account, and Open-Meteo's geocoding
/// service is the fallback that also returns *several* candidates so the user
/// can pick between the four Springfields.
public enum WeatherGeocoder {
    /// Results for a search box, best match first.
    public static func search(_ query: String, limit: Int = 8) async -> [GeocodedPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results = await openMeteoSearch(trimmed, limit: limit)
        // Open-Meteo indexes populated places, not street addresses. Anything
        // with a house number in it comes back empty, so ask Apple as well and
        // put its answer first when it found something the other did not.
        if let appleResult = await appleGeocode(trimmed),
           !results.contains(where: { $0.isRoughly(appleResult) }) {
            results.insert(appleResult, at: 0)
        }
        return Array(results.prefix(limit))
    }

    /// The single best match, for resolving a saved query at refresh time.
    public static func resolve(_ query: String) async -> GeocodedPlace? {
        await search(query, limit: 1).first
    }

    // MARK: - Open-Meteo geocoding (cities, towns, regions)

    static func openMeteoSearch(_ query: String, limit: Int) async -> [GeocodedPlace] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: String(max(1, min(20, limit)))),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url,
              let data = try? await WebQuerySource.fetch(url: url),
              let json = try? JSONValue.parse(data),
              let entries = json["results"]?.arrayValue else { return [] }
        return entries.compactMap(place(from:))
    }

    static func place(from entry: JSONValue) -> GeocodedPlace? {
        guard let name = entry["name"]?.stringValue,
              let latitude = entry["latitude"]?.doubleValue,
              let longitude = entry["longitude"]?.doubleValue else { return nil }
        let detail = [entry["admin1"]?.stringValue, entry["country"]?.stringValue]
            .compactMap { $0 }
            .joined(separator: ", ")
        return GeocodedPlace(name: name, detail: detail,
                             latitude: latitude, longitude: longitude)
    }

    // MARK: - Apple geocoding (street addresses, postal codes)

    static func appleGeocode(_ query: String) async -> GeocodedPlace? {
        #if canImport(CoreLocation)
        guard let placemark = try? await CLGeocoder().geocodeAddressString(query).first,
              let location = placemark.location else { return nil }
        let name = placemark.name ?? placemark.locality ?? query
        let detail = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .filter { $0 != name }
            .joined(separator: ", ")
        return GeocodedPlace(name: name, detail: detail,
                             latitude: location.coordinate.latitude,
                             longitude: location.coordinate.longitude)
        #else
        return nil
        #endif
    }
}

extension GeocodedPlace {
    /// Within about a kilometre — close enough that two geocoders have found
    /// the same place and only one of them should be offered.
    func isRoughly(_ other: GeocodedPlace) -> Bool {
        abs(latitude - other.latitude) < 0.01 && abs(longitude - other.longitude) < 0.01
    }

    public var displayName: String {
        detail.isEmpty ? name : "\(name), \(detail)"
    }
}

/// Remembers what a place query resolved to, so a weather panel geocodes once
/// rather than on every refresh — and keeps working when the geocoder is
/// unreachable or rate-limited.
///
/// Kept in the app group so widgets share the same answers as the app.
public enum WeatherLocationCache {
    private static let defaultsKey = "sb.weather.places"

    private static var store: UserDefaults {
        UserDefaults(suiteName: SBIdentifiers.appGroup) ?? .standard
    }

    public static func cached(for query: String) -> GeocodedPlace? {
        guard let raw = store.dictionary(forKey: defaultsKey)?[query.lowercased()] as? Data,
              let place = try? JSONDecoder().decode(GeocodedPlace.self, from: raw) else {
            return nil
        }
        return place
    }

    public static func remember(_ place: GeocodedPlace, for query: String) {
        guard let data = try? JSONEncoder().encode(place) else { return }
        var all = store.dictionary(forKey: defaultsKey) ?? [:]
        all[query.lowercased()] = data
        store.set(all, forKey: defaultsKey)
    }

    /// The cached answer, or a fresh lookup that is then cached.
    public static func resolve(_ query: String) async -> GeocodedPlace? {
        if let cached = cached(for: query) { return cached }
        guard let found = await WeatherGeocoder.resolve(query) else { return nil }
        remember(found, for: query)
        return found
    }
}
