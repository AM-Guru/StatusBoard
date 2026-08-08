import Foundation

/// Where the moon is and how much of it is lit, at one instant.
public struct MoonPosition: Equatable, Sendable {
    /// Degrees above the horizon; negative when the moon is down.
    public let altitude: Double
    /// How far the moon runs behind the sun, in hours of a 24-hour day —
    /// −12…12. This is what places it on a solar dial: a new moon shares the
    /// sun's spot, a full moon sits opposite it, and a first-quarter moon
    /// trails six hours behind.
    public let hoursFromSun: Double
    /// Fraction of the disc lit, 0…1.
    public let illumination: Double
    /// The cycle, 0 at new moon through 0.5 at full and back to 1. Below 0.5
    /// the moon is waxing.
    public let phase: Double

    public var isWaxing: Bool { phase < 0.5 }

    /// The eight names people actually use for the phases.
    public var phaseName: String {
        switch phase {
        case ..<0.02: return "New Moon"
        case ..<0.23: return "Waxing Crescent"
        case ..<0.27: return "First Quarter"
        case ..<0.48: return "Waxing Gibbous"
        case ..<0.52: return "Full Moon"
        case ..<0.73: return "Waning Gibbous"
        case ..<0.77: return "Last Quarter"
        case ..<0.98: return "Waning Crescent"
        default: return "New Moon"
        }
    }

    public init(altitude: Double, hoursFromSun: Double, illumination: Double, phase: Double) {
        self.altitude = altitude
        self.hoursFromSun = hoursFromSun
        self.illumination = illumination
        self.phase = phase
    }
}

/// The moon, worked out on the device the same way the sun is — no service,
/// nothing about the user's place leaving the machine.
///
/// Uses the low-precision lunar series (the one behind SunCalc and the
/// Astronomical Almanac's abridged tables): good to a fraction of a degree in
/// position and a percent or so in illumination, which is far finer than a dot
/// on a dial can show.
public enum MoonCalculator {
    /// Mean distance to the sun, in kilometres — only the ratio to the moon's
    /// distance matters, and that is what turns elongation into a phase.
    private static let sunDistance = 149_598_000.0

    public static func position(at date: Date, latitude: Double,
                                longitude: Double) -> MoonPosition {
        let days = SolarCalculator.daysSinceJ2000(date)
        let moon = coordinates(daysSinceJ2000: days)
        let sun = SolarCalculator.position(daysSinceJ2000: days)

        let hourAngle = SolarCalculator.siderealTime(daysSinceJ2000: days, longitude: longitude)
            - moon.rightAscension
        let latitudeRadians = SolarCalculator.radians(latitude)
        let sine = sin(latitudeRadians) * sin(moon.declination)
            + cos(latitudeRadians) * cos(moon.declination) * cos(hourAngle)
        let altitude = SolarCalculator.degrees(asin(min(1, max(-1, sine))))

        // How far round the sky the moon is from the sun: its elongation gives
        // the phase, and the difference in right ascension gives the hours
        // between them.
        let separation = sun.rightAscension - moon.rightAscension
        let elongation = acos(min(1, max(-1,
            sin(sun.declination) * sin(moon.declination)
            + cos(sun.declination) * cos(moon.declination) * cos(separation))))
        let inclination = atan2(sunDistance * sin(elongation),
                                moon.distance - sunDistance * cos(elongation))
        let limbAngle = atan2(cos(sun.declination) * sin(separation),
                              sin(sun.declination) * cos(moon.declination)
                              - cos(sun.declination) * sin(moon.declination) * cos(separation))
        let illumination = (1 + cos(inclination)) / 2
        let phase = 0.5 + 0.5 * inclination * (limbAngle < 0 ? -1 : 1) / .pi

        return MoonPosition(altitude: altitude,
                            hoursFromSun: wrappedHours(SolarCalculator.degrees(separation) / 15),
                            illumination: illumination,
                            phase: phase.truncatingRemainder(dividingBy: 1))
    }

    /// Geocentric position of the moon: declination and right ascension in
    /// radians, distance in kilometres.
    private static func coordinates(daysSinceJ2000 days: Double)
    -> (declination: Double, rightAscension: Double, distance: Double) {
        // Mean longitude, mean anomaly and mean distance (argument of latitude).
        let meanLongitude = SolarCalculator.radians(218.316 + 13.176396 * days)
        let meanAnomaly = SolarCalculator.radians(134.963 + 13.064993 * days)
        let meanDistance = SolarCalculator.radians(93.272 + 13.229350 * days)

        let eclipticLongitude = meanLongitude
            + SolarCalculator.radians(6.289) * sin(meanAnomaly)
        let eclipticLatitude = SolarCalculator.radians(5.128) * sin(meanDistance)
        let distance = 385_001 - 20_905 * cos(meanAnomaly)

        let obliquity = SolarCalculator.radians(23.4397)
        let rightAscension = atan2(
            sin(eclipticLongitude) * cos(obliquity)
                - tan(eclipticLatitude) * sin(obliquity),
            cos(eclipticLongitude))
        let declination = asin(sin(eclipticLatitude) * cos(obliquity)
                               + cos(eclipticLatitude) * sin(obliquity) * sin(eclipticLongitude))
        return (declination, rightAscension, distance)
    }

    /// Folds an hour difference into −12…12, so "eleven hours behind" reads as
    /// thirteen hours ahead rather than as most of a day.
    private static func wrappedHours(_ hours: Double) -> Double {
        var value = hours.truncatingRemainder(dividingBy: 24)
        if value > 12 { value -= 24 }
        if value < -12 { value += 24 }
        return value
    }
}
