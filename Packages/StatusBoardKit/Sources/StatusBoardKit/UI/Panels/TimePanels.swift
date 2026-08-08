import SwiftUI

/// A clock panel: one ticking timeline, dispatched to whichever face the
/// panel has chosen. Faces live in `ClockFaces.swift`.
struct ClockPanelContent: View {
    let settings: PanelSettings

    var timeZone: TimeZone { settings.clockTimeZone }

    /// How often the face has to be redrawn. Only faces that draw seconds need
    /// a second-by-second timeline; the sun faces move slowly enough that a
    /// minute is plenty, and a panel that redraws less costs less on a TV
    /// that has been showing the same board for a week.
    private var tick: TimeInterval {
        switch settings.clockStyle {
        case .sunTimes: return 60
        case .sunArc: return settings.showsSeconds ? 1 : 30
        default: return settings.showsSeconds ? 1 : 30
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: tick)) { context in
            face(at: context.date)
        }
    }

    @ViewBuilder
    private func face(at date: Date) -> some View {
        switch settings.clockStyle {
        case .lcd:
            LCDClockFace(settings: settings, date: date)
        case .flip:
            FlipClockFace(settings: settings, date: date)
        case .analog:
            AnalogClockFace(settings: settings, date: date)
        case .dial:
            SolarDialClockFace(settings: settings, date: date)
        case .modular:
            ModularClockFace(settings: settings, date: date)
        case .solar:
            SolarClockFace(settings: settings, date: date)
        case .sunBand:
            TwilightBandClockFace(settings: settings, date: date)
        case .sunArc:
            SunArcClockFace(settings: settings, date: date)
        case .sunTimes:
            SunTimesClockFace(settings: settings, date: date)
        }
    }
}

/// Days / hours / minutes / seconds until a target date.
struct CountdownPanelContent: View {
    @Environment(\.sbStyle) private var sbStyle
    let settings: PanelSettings

    @Environment(\.panelAccent) private var accent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let target = settings.targetDate {
                let remaining = max(0, target.timeIntervalSince(context.date))
                GeometryReader { proxy in
                    HStack(spacing: proxy.size.width * 0.03) {
                        segment(Int(remaining) / 86400, "DAYS", proxy: proxy)
                        segment(Int(remaining) % 86400 / 3600, "HRS", proxy: proxy)
                        segment(Int(remaining) % 3600 / 60, "MIN", proxy: proxy)
                        segment(Int(remaining) % 60, "SEC", proxy: proxy)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .padding(8)
            } else {
                ErrorView(message: "Pick a target date in the panel settings")
            }
        }
    }

    func segment(_ value: Int, _ label: String, proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Text(String(format: "%02d", value))
                .font(SBTheme.lcdFont(size: min(proxy.size.height * 0.42, proxy.size.width * 0.14)))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(label)
                .font(SBTheme.titleFont(size: min(proxy.size.height * 0.12, 12)))
                .foregroundStyle(sbStyle.textSecondary)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Static text panel.
struct TextPanelContent: View {
    @Environment(\.sbStyle) private var sbStyle
    let settings: PanelSettings

    var body: some View {
        GeometryReader { proxy in
            Text(settings.text ?? "Edit this panel to set its text")
                .font(.system(size: min(proxy.size.height * 0.25, 22),
                              weight: .medium, design: .rounded))
                .foregroundStyle(settings.text == nil ? sbStyle.textSecondary : sbStyle.textPrimary)
                .minimumScaleFactor(0.4)
                .multilineTextAlignment(.leading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .padding(12)
    }
}
