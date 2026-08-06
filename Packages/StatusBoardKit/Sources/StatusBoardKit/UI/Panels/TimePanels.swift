import SwiftUI

/// The classic Status Board clock: big LCD digits, live seconds.
struct ClockPanelContent: View {
    let settings: PanelSettings

    @Environment(\.panelAccent) private var accent

    var timeZone: TimeZone {
        settings.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: settings.showsSeconds ? 1 : 30)) { context in
            GeometryReader { proxy in
                VStack(spacing: 2) {
                    Text(timeString(context.date))
                        .font(SBTheme.lcdFont(size: min(proxy.size.height * 0.52, proxy.size.width * 0.16)))
                        .foregroundStyle(accent)
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text(dateString(context.date))
                        .font(SBTheme.titleFont(size: min(proxy.size.height * 0.14, 15)))
                        .foregroundStyle(SBTheme.textSecondary)
                        .kerning(1.2)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .padding(6)
    }

    func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = settings.showsSeconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }

    func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM"
        var text = formatter.string(from: date).uppercased()
        if let zoneID = settings.timeZoneID, zoneID != TimeZone.current.identifier {
            text += "  ·  " + (timeZone.abbreviation() ?? zoneID)
        }
        return text
    }
}

/// Days / hours / minutes / seconds until a target date.
struct CountdownPanelContent: View {
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
                .foregroundStyle(SBTheme.textSecondary)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Static text panel.
struct TextPanelContent: View {
    let settings: PanelSettings

    var body: some View {
        GeometryReader { proxy in
            Text(settings.text ?? "Edit this panel to set its text")
                .font(.system(size: min(proxy.size.height * 0.25, 22),
                              weight: .medium, design: .rounded))
                .foregroundStyle(settings.text == nil ? SBTheme.textSecondary : SBTheme.textPrimary)
                .minimumScaleFactor(0.4)
                .multilineTextAlignment(.leading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .padding(12)
    }
}
