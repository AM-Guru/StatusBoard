import SwiftUI

/// Panel chrome (title bar, background, border) plus kind-dispatched content.
public struct PanelView: View {
    let panel: Panel
    let record: SnapshotRecord?
    /// The board this panel is sitting on. Panels rendered off a board — in a
    /// widget, on the watch, in a list — get the default look.
    let boardAppearance: BoardAppearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(panel: Panel, record: SnapshotRecord?,
                boardAppearance: BoardAppearance = BoardAppearance()) {
        self.panel = panel
        self.record = record
        self.boardAppearance = boardAppearance
    }

    var showsTitleBar: Bool {
        if panel.settings.appearance.hidesTitleBar { return false }
        switch panel.kind {
        case .clock, .countdown, .text: return !panel.title.isEmpty && panel.title != panel.kind.displayName
        default: return true
        }
    }

    private var appearance: PanelAppearance { panel.settings.appearance }

    private var theme: SBThemeName {
        SBPanelStyle.themeName(panel: panel, board: boardAppearance)
    }

    /// The panel's colors, plus whatever its live data wants to say about them.
    /// An accent the user picked by hand always wins over a dynamic one.
    private var resolved: (style: SBPanelStyle, dynamic: SBDynamicAppearance) {
        let base = SBPanelStyle.resolve(panel: panel, board: boardAppearance)
        let dynamic = SBDynamicResolver.resolve(panel: panel, snapshot: record?.snapshot,
                                                style: base)
        guard panel.settings.accentColorHex == nil, let tint = dynamic.tint else {
            return (base, dynamic)
        }
        return (SBPanelStyle.resolve(panel: panel, board: boardAppearance,
                                     dynamicAccent: tint), dynamic)
    }

    public var body: some View {
        let resolution = resolved
        let style = resolution.style
        let dynamic = resolution.dynamic
        let shape = RoundedRectangle(cornerRadius: appearance.resolvedCornerRadius(theme: theme),
                                     style: .continuous)
        VStack(spacing: 0) {
            if showsTitleBar {
                HStack(spacing: 6) {
                    Image(systemName: panel.kind.symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(style.accent)
                    Text(panel.title.uppercased())
                        .font(theme.panelTitleFont(size: 11))
                        .foregroundStyle(style.textSecondary)
                        .kerning(1.5)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let record, panel.kind.isFetched {
                        StalenessDot(updatedAt: record.updatedAt,
                                     refreshSeconds: panel.settings.refreshSeconds)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .opacity(min(1, max(0, appearance.contentOpacity)))
        .environment(\.panelAccent, style.accent)
        .environment(\.sbStyle, style)
        .background {
            PanelBackgroundView(appearance: appearance, theme: theme,
                                dynamic: dynamic, accent: style.accent)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            appearance.resolvedBorderColor(theme: theme,
                                           increasedContrast: colorSchemeContrast == .increased),
            lineWidth: colorSchemeContrast == .increased
                ? max(2, appearance.resolvedBorderWidth(theme: theme))
                : appearance.resolvedBorderWidth(theme: theme)))
        .overlay {
            SBThemePanelChrome(theme: theme, accent: style.accent,
                               cornerRadius: appearance.resolvedCornerRadius(theme: theme))
                .clipShape(shape)
        }
        .shadow(color: appearance.glowRadius > 0 ? style.accent.opacity(0.55) : .clear,
                radius: appearance.glowRadius)
        // A panel speaks as one element: charts and LCD digits are decorative
        // shapes, so VoiceOver reads a written summary instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilitySummary.panelLabel(panel, snapshot: record?.snapshot))
        .accessibilityHint(panel.kind.isFetched ? "Triple-tap to refresh" : "")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    var content: some View {
        switch panel.kind {
        case .clock:
            ClockPanelContent(settings: panel.settings)
        case .countdown:
            CountdownPanelContent(settings: panel.settings)
        case .text:
            TextPanelContent(settings: panel.settings)
        case .webClip:
            WebClipPanelContent(panel: panel, record: record)
        case .graph:
            SnapshotContentView(record: record, settings: panel.settings)
        case .progress:
            switch record?.snapshot {
            case .number(let value, _):
                ProgressContentView(value: value, settings: panel.settings)
            case .error(let message):
                ErrorView(message: message)
            default:
                WaitingView()
            }
        case .mcp:
            switch record?.snapshot {
            case .text(let text):
                BigTextView(text: text, isMonospace: true)
            default:
                SnapshotContentView(record: record, settings: panel.settings)
            }
        case .grades:
            if case .grades(let grades)? = record?.snapshot {
                GradesPanelView(grades: grades, settings: panel.settings)
            } else {
                SnapshotContentView(record: record, settings: panel.settings)
            }
        case .schedule:
            if case .schedule(let classes)? = record?.snapshot {
                SchedulePanelView(classes: classes, settings: panel.settings)
            } else {
                SnapshotContentView(record: record, settings: panel.settings)
            }
        case .assignments:
            if case .assignments(let digest)? = record?.snapshot {
                AssignmentsPanelView(digest: digest, settings: panel.settings)
            } else {
                SnapshotContentView(record: record, settings: panel.settings)
            }
        case .tessie:
            if case .vehicle(let vehicle)? = record?.snapshot {
                TessiePanelView(vehicle: vehicle, settings: panel.settings)
            } else {
                SnapshotContentView(record: record, settings: panel.settings)
            }
        case .homeKit where panel.settings.homeMode == .camera:
            // HomeKit hands cameras over as a view, not as frames, so this
            // panel draws a live stream instead of a snapshot. Home Assistant
            // cameras arrive as images and fall through to the renderer below.
            HomeKitCameraPanelView(panel: panel)
        case .weather, .feed, .calendar, .image, .table, .status, .bridge,
             .github, .appStoreConnect, .supabase, .logs, .health, .canvas,
             .k12schedule, .homeKit, .homeAssistant, .nest:
            SnapshotContentView(record: record, settings: panel.settings)
        }
    }
}

/// Small dot showing whether the panel's data is fresh.
struct StalenessDot: View {
    let updatedAt: Date
    let refreshSeconds: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let age = context.date.timeIntervalSince(updatedAt)
            let stale = age > max(120, refreshSeconds * 3)
            Circle()
                .fill(stale ? SBTheme.warn : SBTheme.good)
                .frame(width: 6, height: 6)
                .opacity(0.9)
                .help("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                .accessibilityHidden(true)
        }
    }
}

extension View {
    @ViewBuilder
    func help(_ text: String) -> some View {
        #if os(macOS)
        self.help(Text(text))
        #else
        self
        #endif
    }
}
