import Foundation

/// Sunrise, sunset and solar noon for one place on one day.
///
/// Both are optional because they genuinely don't exist everywhere: above the
/// Arctic and Antarctic circles the sun can stay up — or stay down — for the
/// whole day, and a face has to say so rather than draw a nonsense arc.
public struct SolarDay: Equatable, Sendable {
    /// Local midnight-to-midnight day these times belong to.
    public let day: Date
    public let sunrise: Date?
    public let sunset: Date?
    /// The sun's highest point. Always exists, even in the polar cases.
    public let solarNoon: Date
    /// The sun never set: 24 hours of daylight.
    public let isPolarDay: Bool
    /// The sun never rose.
    public let isPolarNight: Bool

    public init(day: Date, sunrise: Date?, sunset: Date?, solarNoon: Date,
                isPolarDay: Bool, isPolarNight: Bool) {
        self.day = day
        self.sunrise = sunrise
        self.sunset = sunset
        self.solarNoon = solarNoon
        self.isPolarDay = isPolarDay
        self.isPolarNight = isPolarNight
    }

    /// Seconds of daylight, or nil on a polar day or night where the question
    /// has no useful answer in this day's terms.
    public var daylight: TimeInterval? {
        guard let sunrise, let sunset, sunset > sunrise else { return nil }
        return sunset.timeIntervalSince(sunrise)
    }

    public func isDaylight(at date: Date) -> Bool {
        if isPolarDay { return true }
        if isPolarNight { return false }
        guard let sunrise, let sunset else { return false }
        return date >= sunrise && date <= sunset
    }

    /// How far through the daylight hours `date` is, 0…1. Clamped, so a time
    /// before sunrise reads 0 and one after sunset reads 1.
    public func daylightProgress(at date: Date) -> Double {
        guard let sunrise, let daylight, daylight > 0 else { return isPolarDay ? 0.5 : 0 }
        return min(1, max(0, date.timeIntervalSince(sunrise) / daylight))
    }
}

/// Sunrise and sunset worked out on the device from the date and a pair of
/// coordinates — no service to call, so the sun faces keep working offline and
/// nothing about where the user is ever leaves the device.
///
/// Implements the standard sunrise equation (the low-precision solar position
/// used by NOAA's calculator), which lands within about a minute of the
/// published tables at temperate latitudes.
public enum SolarCalculator {
    /// The sun's centre this far below the horizon at the moment we call it
    /// risen or set — the usual −0.833°, which allows for refraction and for
    /// the disc's radius.
    private static let horizonAngle = -0.833

    private static let julianUnixEpoch = 2440587.5

    /// The sun's day for whatever local day `date` falls on.
    public static func day(containing date: Date, latitude: Double, longitude: Double,
                           timeZone: TimeZone = .current) -> SolarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: date)
        // Noon local is the anchor: the algorithm solves for the transit
        // nearest a given instant, and local noon is unambiguously inside the
        // day the caller asked about however far the place is from its meridian.
        let localNoon = startOfDay.addingTimeInterval(12 * 3600)
        return solve(anchor: localNoon, day: startOfDay,
                     latitude: latitude, longitude: longitude)
    }

    /// The next sunrise strictly after `date` — what a face needs overnight,
    /// when today's sunrise has long passed.
    public static func nextSunrise(after date: Date, latitude: Double, longitude: Double,
                                   timeZone: TimeZone = .current) -> Date? {
        for offset in 0...3 {
            let probe = date.addingTimeInterval(Double(offset) * 86400)
            let solar = day(containing: probe, latitude: latitude, longitude: longitude,
                            timeZone: timeZone)
            if let sunrise = solar.sunrise, sunrise > date { return sunrise }
        }
        return nil
    }

    /// The next sunset strictly after `date`.
    public static func nextSunset(after date: Date, latitude: Double, longitude: Double,
                                  timeZone: TimeZone = .current) -> Date? {
        for offset in 0...3 {
            let probe = date.addingTimeInterval(Double(offset) * 86400)
            let solar = day(containing: probe, latitude: latitude, longitude: longitude,
                            timeZone: timeZone)
            if let sunset = solar.sunset, sunset > date { return sunset }
        }
        return nil
    }

    // MARK: - The equation

    private static func solve(anchor: Date, day: Date,
                              latitude: Double, longitude: Double) -> SolarDay {
        let julianAnchor = anchor.timeIntervalSince1970 / 86400 + julianUnixEpoch
        // Whole days since J2000.0, corrected for the fraction of a day the
        // place sits away from Greenwich.
        let n = (julianAnchor - 2451545.0 - 0.0009 - (-longitude / 360)).rounded()
        let meanSolarTime = n + 0.0009 + (-longitude / 360)

        // Mean anomaly, equation of the centre, ecliptic longitude.
        let meanAnomaly = (357.5291 + 0.98560028 * meanSolarTime)
            .truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(radians(meanAnomaly))
            + 0.0200 * sin(radians(2 * meanAnomaly))
            + 0.0003 * sin(radians(3 * meanAnomaly))
        let eclipticLongitude = (meanAnomaly + center + 180 + 102.9372)
            .truncatingRemainder(dividingBy: 360)

        let transit = 2451545.0 + meanSolarTime
            + 0.0053 * sin(radians(meanAnomaly))
            - 0.0069 * sin(radians(2 * eclipticLongitude))
        let solarNoon = date(fromJulian: transit)

        let declination = asin(sin(radians(eclipticLongitude)) * sin(radians(23.4397)))
        let numerator = sin(radians(horizonAngle)) - sin(radians(latitude)) * sin(declination)
        let denominator = cos(radians(latitude)) * cos(declination)
        // Exactly at a pole the denominator vanishes; the sun is then up or
        // down for the whole day depending on which side of the horizon its
        // declination puts it, which is what the numerator's sign says.
        let cosHourAngle = denominator == 0 ? (numerator > 0 ? 2.0 : -2.0)
                                            : numerator / denominator

        // |cos ω| > 1 means the sun's path never crosses the horizon: it is
        // either up all day or down all day, depending on which side it misses.
        guard abs(cosHourAngle) <= 1 else {
            let polarNight = cosHourAngle > 1
            return SolarDay(day: day, sunrise: nil, sunset: nil, solarNoon: solarNoon,
                            isPolarDay: !polarNight, isPolarNight: polarNight)
        }

        let hourAngle = degrees(acos(cosHourAngle))
        let sunrise = date(fromJulian: transit - hourAngle / 360)
        let sunset = date(fromJulian: transit + hourAngle / 360)
        return SolarDay(day: day, sunrise: sunrise, sunset: sunset, solarNoon: solarNoon,
                        isPolarDay: false, isPolarNight: false)
    }

    private static func date(fromJulian julian: Double) -> Date {
        Date(timeIntervalSince1970: (julian - julianUnixEpoch) * 86400)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
