import SwiftUI

/// Panel chrome (title bar, background, border) plus kind-dispatched content.
public struct PanelView: View {
    let panel: Panel
    let record: SnapshotRecord?

    public init(panel: Panel, record: SnapshotRecord?) {
        self.panel = panel
        self.record = record
    }

    var showsTitleBar: Bool {
        switch panel.kind {
        case .clock, .countdown, .text: return !panel.title.isEmpty && panel.title != panel.kind.displayName
        default: return true
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsTitleBar {
                HStack(spacing: 6) {
                    Image(systemName: panel.kind.symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(panel.settings.accentColor ?? SBTheme.accent)
                    Text(panel.title.uppercased())
                        .font(SBTheme.titleFont(size: 11))
                        .foregroundStyle(SBTheme.textSecondary)
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
        .environment(\.panelAccent, panel.settings.accentColor ?? SBTheme.accent)
        .background(SBTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SBTheme.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SBTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(SBTheme.panelBorder, lineWidth: 1)
        )
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
        case .weather, .feed, .calendar, .image, .table, .status, .bridge,
             .github, .appStoreConnect, .supabase, .logs, .health, .canvas,
             .k12schedule:
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
