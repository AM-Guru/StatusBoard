import Foundation

/// Looks up the posted speed limit for the road a vehicle is on.
///
/// No Apple framework publishes speed limits, and neither Tessie nor Tesla
/// carry them — `speed_limit_mode` is the governor an owner sets on the
/// touchscreen, not the sign at the roadside. OpenStreetMap does, in the
/// `maxspeed` tag, so that is where this reads from.
///
/// **This sends the vehicle's coordinates to overpass-api.de.** Nothing else
/// leaves the device: no identifier, no token, no vehicle name. The panel says
/// so in its settings, and it only ever asks while the car is actually moving.
///
/// Picking the *nearest* way matters more than it sounds. A freeway usually
/// runs alongside a frontage road with a very different limit, so a query that
/// returns "some road within 40 m" is wrong often enough to be dangerous to
/// trust. Every candidate way's geometry is fetched and measured.
public enum RoadSpeedLimit {
    /// Ways further than this from the car are ignored outright.
    static let searchRadiusMeters = 45.0

    public static func lookup(latitude: Double, longitude: Double) async -> Double? {
        await Cache.shared.limit(latitude: latitude, longitude: longitude)
    }

    // MARK: - Query

    static func fetch(latitude: Double, longitude: Double) async throws -> Double? {
        let query = """
        [out:json][timeout:10];
        way(around:\(Int(searchRadiusMeters)),\(latitude),\(longitude))\
        ["highway"]["maxspeed"];
        out tags geom 12;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = Data("data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Overpass is a volunteer-run service and asks clients to identify
        // themselves so it can throttle rather than ban.
        request.setValue("StatusBoard/1.0 (https://statusboard.am.guru)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let json = try JSONValue.parse(data)
        return nearestLimit(in: json, latitude: latitude, longitude: longitude)
    }

    /// The `maxspeed` of whichever returned way passes closest to the car.
    static func nearestLimit(in json: JSONValue, latitude: Double, longitude: Double) -> Double? {
        var best: (distance: Double, mph: Double)?
        for element in json["elements"]?.arrayValue ?? [] {
            guard let raw = element["tags"]?["maxspeed"]?.stringValue,
                  let mph = parseMaxSpeed(raw) else { continue }
            let geometry = (element["geometry"]?.arrayValue ?? []).compactMap {
                point -> (Double, Double)? in
                guard let lat = point["lat"]?.doubleValue,
                      let lon = point["lon"]?.doubleValue else { return nil }
                return (lat, lon)
            }
            guard !geometry.isEmpty else { continue }
            let distance = distanceMeters(fromLatitude: latitude, longitude: longitude,
                                          toPolyline: geometry)
            guard distance <= searchRadiusMeters else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, mph)
            }
        }
        return best?.mph
    }

    /// OpenStreetMap's `maxspeed` is km/h unless a unit is spelled out.
    /// Advisory strings ("none", "walk", "RU:urban") carry no number and are
    /// treated as unknown rather than guessed at.
    static func parseMaxSpeed(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let value = text.leadingNumber, value > 0 else { return nil }
        if text.contains("mph") { return value }
        if text.contains("knots") { return value * 1.15078 }
        return value / 1.609344
    }

    // MARK: - Geometry

    /// Metres from a point to the closest point on a polyline, using an
    /// equirectangular approximation. Over the tens of metres this deals in,
    /// the error is centimetres.
    static func distanceMeters(fromLatitude latitude: Double, longitude: Double,
                               toPolyline points: [(Double, Double)]) -> Double {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(latitude * .pi / 180)

        func project(_ point: (Double, Double)) -> (x: Double, y: Double) {
            ((point.1 - longitude) * metersPerDegreeLon,
             (point.0 - latitude) * metersPerDegreeLat)
        }

        var shortest = Double.greatestFiniteMagnitude
        let projected = points.map(project)
        guard let first = projected.first else { return shortest }
        shortest = hypot(first.x, first.y)
        for index in projected.indices.dropLast() {
            let a = projected[index]
            let b = projected[index + 1]
            shortest = min(shortest, distanceToSegment(a: a, b: b))
        }
        return shortest
    }

    /// Distance from the origin to segment a→b.
    private static func distanceToSegment(a: (x: Double, y: Double),
                                          b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(a.x, a.y) }
        // Projection of the origin onto the segment, clamped to its ends.
        let t = max(0, min(1, -(a.x * dx + a.y * dy) / lengthSquared))
        return hypot(a.x + t * dx, a.y + t * dy)
    }

    // MARK: - Cache

    /// Overpass is free and volunteer-run, and a board can hold several
    /// vehicle panels refreshing on their own timers. This keeps one lookup
    /// per stretch of road rather than one per refresh.
    actor Cache {
        static let shared = Cache()

        private var coordinate: (latitude: Double, longitude: Double)?
        private var value: Double?
        private var fetchedAt: Date?

        /// Re-query only once the car has moved this far…
        private let staleDistanceMeters = 80.0
        /// …or this long has passed, whichever comes first.
        private let staleAfter: TimeInterval = 90

        func limit(latitude: Double, longitude: Double) async -> Double? {
            if let coordinate, let fetchedAt,
               Date().timeIntervalSince(fetchedAt) < staleAfter,
               RoadSpeedLimit.distanceMeters(fromLatitude: latitude, longitude: longitude,
                                             toPolyline: [coordinate]) < staleDistanceMeters {
                return value
            }
            // Record the attempt before awaiting, so a failing or slow
            // Overpass can't turn every refresh into another request.
            coordinate = (latitude, longitude)
            fetchedAt = Date()
            value = (try? await RoadSpeedLimit.fetch(latitude: latitude,
                                                     longitude: longitude)) ?? nil
            return value
        }

        func reset() {
            coordinate = nil
            value = nil
            fetchedAt = nil
        }
    }
}

private extension String {
    /// The first run of digits (with an optional decimal part) in the string,
    /// so "50 mph" and "RU:urban" are told apart without a regex.
    var leadingNumber: Double? {
        var digits = ""
        for character in self {
            if character.isNumber || (character == "." && !digits.isEmpty) {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}
