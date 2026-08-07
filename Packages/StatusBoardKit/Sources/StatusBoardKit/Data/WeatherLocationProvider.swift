import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// "Current Location" for weather panels.
///
/// Deliberately small: one on-demand fix, no continuous tracking, and the last
/// known position cached in the app group so a refresh (or a widget, or a
/// board opened before the fix lands) still has somewhere to report on. The
/// coordinates never leave the device except as the latitude and longitude in
/// the forecast request the user asked for.
public actor WeatherLocationProvider {
    public static let shared = WeatherLocationProvider()

    /// Reuse a fix for this long before asking Core Location again. Weather
    /// does not change meaningfully over a few hundred metres.
    private static let fixLifetime: TimeInterval = 15 * 60

    private var lastFix: (place: GeocodedPlace, at: Date)?

    public enum LocationError: LocalizedError {
        case denied
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .denied:
                return "Location access is off for Status Board. Turn it on in Settings, or pick a city instead."
            case .unavailable:
                return "Could not get this device's location"
            }
        }
    }

    /// The device's position, named where possible. Throws rather than
    /// returning nil so the panel can explain *why* it has nothing to show.
    public func currentPlace() async throws -> GeocodedPlace {
        if let lastFix, Date().timeIntervalSince(lastFix.at) < Self.fixLifetime {
            return lastFix.place
        }
        #if canImport(CoreLocation)
        let coordinate = try await SBLocationFix.request()
        let name = await reverseGeocodedName(coordinate) ?? "Current Location"
        let place = GeocodedPlace(name: name, detail: "",
                                  latitude: coordinate.latitude,
                                  longitude: coordinate.longitude)
        lastFix = (place, Date())
        WeatherLocationCache.remember(place, for: Self.cacheKey)
        return place
        #else
        if let remembered = WeatherLocationCache.cached(for: Self.cacheKey) { return remembered }
        throw LocationError.unavailable
        #endif
    }

    /// The last place this device was, without asking for a new fix.
    public nonisolated static var lastKnown: GeocodedPlace? {
        WeatherLocationCache.cached(for: cacheKey)
    }

    nonisolated static let cacheKey = "__sb.current-location"

    /// CLGeocoder is soft-deprecated in favour of MapKit's request objects,
    /// which do not exist on the OS versions this app still supports. It keeps
    /// working, and it is the only geocoder available across all five
    /// platforms here.
    private func reverseGeocodedName(_ coordinate: SBCoordinate) async -> String? {
        #if canImport(CoreLocation)
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        return placemark.locality ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea ?? placemark.name
        #else
        return nil
        #endif
    }
}

/// Latitude/longitude without dragging CoreLocation into every file.
public struct SBCoordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

#if canImport(CoreLocation)
/// One-shot Core Location request, bridged to async/await.
///
/// `CLLocationManager` insists on being created and used from the main thread
/// and answers through a delegate, so the manager is held for the lifetime of
/// the request — a local one would deallocate before the callback and the
/// continuation would never resume.
@MainActor
final class SBLocationFix: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<SBCoordinate, Error>?
    private static var live: SBLocationFix?

    static func request() async throws -> SBCoordinate {
        let fix = SBLocationFix()
        live = fix
        defer { live = nil }
        return try await fix.start()
    }

    private func start() async throws -> SBCoordinate {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            self.manager = manager
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(WeatherLocationProvider.LocationError.denied))
            default:
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<SBCoordinate, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .notDetermined:
                break
            case .denied, .restricted:
                finish(.failure(WeatherLocationProvider.LocationError.denied))
            default:
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last.map {
            SBCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        Task { @MainActor in
            if let coordinate {
                finish(.success(coordinate))
            } else {
                finish(.failure(WeatherLocationProvider.LocationError.unavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }
}
#endif
