import SwiftUI

/// How the sky is behaving, distilled from a WMO weather code.
public enum WeatherScene: String, Equatable, Sendable, CaseIterable {
    case clear
    case partlyCloudy
    case overcast
    case fog
    case drizzle
    case rain
    case snow
    case thunder

    public var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly Cloudy"
        case .overcast: return "Overcast"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .thunder: return "Thunderstorms"
        }
    }

    /// WMO code → scene. Mirrors `WeatherSource.condition(for:)`, but grouped
    /// by what the sky *looks* like rather than what it is called.
    public static func forCode(_ code: Int) -> WeatherScene {
        switch code {
        case 0: return .clear
        case 1, 2: return .partlyCloudy
        case 3: return .overcast
        case 45, 48: return .fog
        case 51...57: return .drizzle
        case 61...67, 80...82: return .rain
        case 71...77, 85, 86: return .snow
        case 95...99: return .thunder
        default: return .partlyCloudy
        }
    }
}

/// The backdrop and tint a panel's own data has asked for.
public struct SBDynamicAppearance: Equatable {
    public enum Backdrop: Equatable {
        case none
        case weather(WeatherReport)
        /// A soft wash of one color — service status, thresholds, lateness.
        case wash(Color)
        /// Sky colors for the time of day, with no weather behind them.
        case timeOfDay
    }

    public var backdrop: Backdrop = .none
    /// Replaces the panel's accent when the data has an opinion about it.
    public var tint: Color?

    public static let none = SBDynamicAppearance()

    public init(backdrop: Backdrop = .none, tint: Color? = nil) {
        self.backdrop = backdrop
        self.tint = tint
    }
}

public enum SBDynamicResolver {
    /// Works out what a panel should look like given what it is currently
    /// showing. Called on every render, so it stays cheap and allocation-free.
    public static func resolve(panel: Panel, snapshot: DataSnapshot?,
                               style: SBPanelStyle) -> SBDynamicAppearance {
        let mode = panel.settings.appearance.dynamic
        guard mode != .off else { return .none }

        switch mode {
        case .off:
            return .none

        case .weather:
            if case .weather(let report)? = snapshot {
                return SBDynamicAppearance(backdrop: .weather(report))
            }
            return SBDynamicAppearance(backdrop: .timeOfDay)

        case .timeOfDay:
            return SBDynamicAppearance(backdrop: .timeOfDay)

        case .status:
            guard let color = statusColor(snapshot: snapshot, settings: panel.settings,
                                          style: style) else { return .none }
            return SBDynamicAppearance(backdrop: .wash(color), tint: color)

        case .threshold:
            guard let color = thresholdColor(panel: panel, snapshot: snapshot, style: style) else {
                return .none
            }
            return SBDynamicAppearance(backdrop: .wash(color), tint: color)

        case .automatic:
            // Weather panels get a sky; anything with a health-like state gets
            // colored by it; numeric panels with alert limits follow those.
            if case .weather(let report)? = snapshot {
                return SBDynamicAppearance(backdrop: .weather(report))
            }
            if let color = statusColor(snapshot: snapshot, settings: panel.settings, style: style) {
                return SBDynamicAppearance(backdrop: .wash(color), tint: color)
            }
            if let color = thresholdColor(panel: panel, snapshot: snapshot, style: style) {
                return SBDynamicAppearance(backdrop: .wash(color), tint: color)
            }
            // A running system tints its own numbers warm or cool, which
            // reads at a glance from across a room — but only tints, since
            // the wash is reserved for things that are actually wrong.
            if case .thermostat(let readout)? = snapshot, readout.status.isConditioning {
                return SBDynamicAppearance(tint: readout.status == .heating
                                           ? style.bad : Color(hex: 0x4AA8FF))
            }
            if panel.kind == .clock || panel.kind == .weather {
                return SBDynamicAppearance(backdrop: .timeOfDay)
            }
            return .none
        }
    }

    /// Green / amber / red from whatever "state" the panel's data carries.
    static func statusColor(snapshot: DataSnapshot?, settings: PanelSettings = PanelSettings(),
                            style: SBPanelStyle) -> Color? {
        switch snapshot {
        case .statuses(let statuses):
            guard !statuses.isEmpty else { return nil }
            if statuses.contains(where: { $0.state == .down }) { return style.bad }
            if statuses.contains(where: { $0.state == .degraded }) { return style.warn }
            if statuses.allSatisfy({ $0.state == .up }) { return style.good }
            return nil
        case .assignments(let digest):
            if !digest.late.isEmpty { return style.bad }
            if !digest.due.isEmpty || !digest.redo.isEmpty { return style.warn }
            return style.good
        case .grades(let grades):
            // A hidden class shouldn't be able to turn the whole panel red.
            let scores = settings.visibleGrades(grades).compactMap(\.score)
            guard let lowest = scores.min() else { return nil }
            if lowest < 70 { return style.bad }
            if lowest < 85 { return style.warn }
            return style.good
        case .homeSensors(let report):
            // Smoke, carbon monoxide and water are the only readings worth
            // repainting a panel over — a door standing open is the reading
            // itself, not an alarm about the whole room.
            let alarms = report.readings.filter {
                [.smoke, .carbonMonoxide, .leak].contains($0.kind) && $0.isActive == true
            }
            return alarms.isEmpty ? nil : style.bad
        case .thermostat(let readout):
            guard readout.isOnline else { return style.warn }
            // Only a real fault colors the panel. "Heating" is a state, not a
            // problem, and a board that glows amber whenever the furnace runs
            // teaches people to ignore the color.
            switch readout.diagnostics?.worstSeverity {
            case .critical: return style.bad
            case .warning: return style.warn
            default: return nil
            }
        case .error:
            return style.bad
        default:
            return nil
        }
    }

    /// Follows the panel's own alert limits, so the colors on screen agree
    /// with the notifications it sends.
    static func thresholdColor(panel: Panel, snapshot: DataSnapshot?,
                               style: SBPanelStyle) -> Color? {
        let above = panel.settings.alertAbove
        let below = panel.settings.alertBelow
        guard above != nil || below != nil else { return nil }
        let value: Double?
        switch snapshot {
        case .number(let number, _): value = number
        case .series(let series): value = series.points.last?.value
        default: value = nil
        }
        guard let value else { return nil }
        if let above {
            if value >= above { return style.bad }
            if value >= above * 0.9 { return style.warn }
        }
        if let below {
            if value <= below { return style.bad }
            if value <= below * 1.1 { return style.warn }
        }
        return style.good
    }
}

/// A soft radial wash of one color, used for status and threshold coloring.
/// Deliberately gentle: the panel still has to be readable, and a full-strength
/// red field behind white text is not.
struct SBWashBackdrop: View {
    let color: Color
    let intensity: Double

    var body: some View {
        let strength = min(1, max(0, intensity))
        ZStack {
            LinearGradient(colors: [color.opacity(0.30 * strength),
                                    color.opacity(0.06 * strength)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [color.opacity(0.26 * strength), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 260)
        }
    }
}

/// Sky colors for the hour of the day, with no weather in them.
struct SBTimeOfDayBackdrop: View {
    let intensity: Double
    var animates: Bool = true

    var body: some View {
        SBAnimatedCanvasHost(animates: animates, period: 60) { time in
            let hour = Self.hour(at: time)
            LinearGradient(colors: Self.colors(forHour: hour).map { $0.opacity(min(1, max(0, intensity))) },
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Local hour as a fraction, from a reference-date timestamp.
    static func hour(at referenceSeconds: Double) -> Double {
        let date = Date(timeIntervalSinceReferenceDate: referenceSeconds)
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
    }

    static func colors(forHour hour: Double) -> [Color] {
        switch hour {
        case ..<5:    return [Color(hex: 0x05070F), Color(hex: 0x121A32)]
        case 5..<7:   return [Color(hex: 0x2A2350), Color(hex: 0xE07A5F)]
        case 7..<11:  return [Color(hex: 0x2E6FA8), Color(hex: 0x9CC9E8)]
        case 11..<16: return [Color(hex: 0x2A83C9), Color(hex: 0xBBE0F5)]
        case 16..<19: return [Color(hex: 0x7A4B7A), Color(hex: 0xF0A15E)]
        case 19..<21: return [Color(hex: 0x1E2247), Color(hex: 0x7B4C77)]
        default:      return [Color(hex: 0x05070F), Color(hex: 0x121A32)]
        }
    }
}
