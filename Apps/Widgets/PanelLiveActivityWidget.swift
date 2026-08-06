#if os(iOS)
import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents
import StatusBoardKit

/// Dynamic Island + Lock Screen presentation for a pinned panel value.
struct PanelLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PanelActivityAttributes.self) { context in
            lockScreenView(context)
        } dynamicIsland: { context in
            let accent = context.attributes.accentHex.flatMap(Color.init(hexString:))
                ?? SBTheme.accent
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.attributes.symbolName)
                            .foregroundStyle(accent)
                        Text(context.attributes.panelTitle.uppercased())
                            .font(SBTheme.titleFont(size: 12))
                            .foregroundStyle(SBTheme.textSecondary)
                            .kerning(1)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.formatted)
                        .font(SBTheme.lcdFont(size: 28))
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Updated \(context.state.updatedAt, format: .relative(presentation: .named))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(SBTheme.textSecondary)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.formatted)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
            } minimal: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(accent)
            }
        }
    }

    private func lockScreenView(_ context: ActivityViewContext<PanelActivityAttributes>) -> some View {
        let accent = context.attributes.accentHex.flatMap(Color.init(hexString:))
            ?? SBTheme.accent
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: context.attributes.symbolName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.panelTitle.uppercased())
                        .font(SBTheme.titleFont(size: 11))
                        .foregroundStyle(SBTheme.textSecondary)
                        .kerning(1)
                    Text("Updated \(context.state.updatedAt, format: .relative(presentation: .named))")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(SBTheme.textSecondary.opacity(0.7))
                }
            }
            Spacer()
            Text(context.state.formatted)
                .font(SBTheme.lcdFont(size: 30))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
        }
        .padding(14)
        .activityBackgroundTint(SBTheme.background.opacity(0.85))
        .activitySystemActionForegroundColor(accent)
    }
}

// MARK: - Control Center (iOS 18)

/// One-tap launcher in Control Center.
struct OpenStatusBoardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.am.statusboard.control.open") {
            ControlWidgetButton(action: OpenStatusBoardIntent()) {
                Label("Status Board", systemImage: "gauge.with.dots.needle.67percent")
            }
        }
        .displayName("Open Status Board")
        .description("Opens your dashboards.")
    }
}

struct OpenStatusBoardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Status Board"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
#endif
