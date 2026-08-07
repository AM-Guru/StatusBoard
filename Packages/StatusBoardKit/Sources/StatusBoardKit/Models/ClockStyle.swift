import Foundation

/// The face a clock panel wears. Every style draws the same time — they differ
/// only in layout, so switching one is safe on any panel size.
///
/// Kept Foundation-only alongside the other model types so the inspector, the
/// VoiceOver summary and the tests can all reason about faces without SwiftUI.
public enum ClockStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The classic Status Board look: big LCD digits over a date line.
    case lcd
    /// Split-flap board — each digit on its own hinged card.
    case flip
    /// Hands on a tick dial, centred in whatever space the panel has.
    case analog
    /// A 24-hour dial with the night drawn as a wedge and the hours running
    /// the whole way round, after the solar watch faces.
    case dial
    /// Oversized time with the date and seconds stacked beside it, after the
    /// modular watch layouts.
    case modular
    /// The sun's path across the panel, sunrise at one end and sunset at the
    /// other, with the sun where it is now.
    case sunArc
    /// Sunrise and sunset as times, with a daylight bar between them.
    case sunTimes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lcd: return "LCD"
        case .flip: return "Flip Board"
        case .analog: return "Analog"
        case .dial: return "24-Hour Dial"
        case .modular: return "Modular"
        case .sunArc: return "Sun Arc"
        case .sunTimes: return "Sunrise & Sunset"
        }
    }

    public var symbolName: String {
        switch self {
        case .lcd: return "textformat.123"
        case .flip: return "rectangle.split.1x2"
        case .analog: return "clock"
        case .dial: return "circle.dotted"
        case .modular: return "rectangle.grid.1x2"
        case .sunArc: return "sun.horizon"
        case .sunTimes: return "sunrise"
        }
    }

    /// Whether the face needs a latitude and longitude to draw anything.
    public var needsLocation: Bool {
        switch self {
        case .sunArc, .sunTimes: return true
        case .lcd, .flip, .analog, .dial, .modular: return false
        }
    }

    /// Faces that put the sun's position to use when a location is set, but
    /// draw fine without one.
    public var usesLocation: Bool { needsLocation || self == .dial }

    /// Whether a seconds toggle means anything on this face.
    public var supportsSeconds: Bool {
        switch self {
        case .sunTimes: return false
        default: return true
        }
    }

    /// The panel shape the face was drawn for — used when a face is chosen in
    /// the inspector so the panel can be resized to suit it.
    public var suggestedSize: (width: Int, height: Int) {
        switch self {
        case .lcd, .flip, .modular: return (3, 1)
        case .analog, .dial: return (2, 2)
        case .sunArc, .sunTimes: return (4, 2)
        }
    }
}

/// Whether a clock reads 13:00 or 1:00 PM.
public enum ClockHourFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Follow the device's region setting.
    case automatic
    case twelve
    case twentyFour

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .twelve: return "12-Hour"
        case .twentyFour: return "24-Hour"
        }
    }

    /// Resolves `automatic` against a locale by asking it for a time format and
    /// looking for the hour symbol it chose.
    public func isTwentyFourHour(locale: Locale = .current) -> Bool {
        switch self {
        case .twelve: return false
        case .twentyFour: return true
        case .automatic:
            let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)
            return template?.contains("a") == false
        }
    }
}
