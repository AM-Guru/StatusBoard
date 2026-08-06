import WidgetKit
import SwiftUI
import AppIntents
import StatusBoardKit

// MARK: - Configuration intent

struct PanelEntity: AppEntity {
    var id: String
    var title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Panel"
    static let defaultQuery = PanelEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct PanelEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PanelEntity] {
        WidgetSharedState.load().panels
            .filter { identifiers.contains($0.key) }
            .map { PanelEntity(id: $0.key, title: $0.title) }
    }

    func suggestedEntities() async throws -> [PanelEntity] {
        WidgetSharedState.load().panels.map { PanelEntity(id: $0.key, title: $0.title) }
    }

    func defaultResult() async -> PanelEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectPanelIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Panel"
    static let description = IntentDescription("Choose which Status Board panel to display.")

    @Parameter(title: "Panel")
    var panel: PanelEntity?
}

// MARK: - Timeline

struct PanelEntry: TimelineEntry {
    let date: Date
    let title: String
    let kind: PanelKind
    let record: SnapshotRecord?
}

struct PanelTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PanelEntry {
        PanelEntry(date: Date(), title: "Status Board", kind: .bridge,
                   record: SnapshotRecord(snapshot: .number(42, unit: "%")))
    }

    func snapshot(for configuration: SelectPanelIntent, in context: Context) async -> PanelEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectPanelIntent, in context: Context) async -> Timeline<PanelEntry> {
        Timeline(entries: [entry(for: configuration)],
                 policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    #if os(watchOS)
    /// Complication gallery choices on the watch: one per panel.
    func recommendations() -> [AppIntentRecommendation<SelectPanelIntent>] {
        WidgetSharedState.load().panels.prefix(8).map { info in
            let intent = SelectPanelIntent()
            intent.panel = PanelEntity(id: info.key, title: info.title)
            return AppIntentRecommendation(intent: intent, description: Text(info.title))
        }
    }
    #endif

    private func entry(for configuration: SelectPanelIntent) -> PanelEntry {
        let state = WidgetSharedState.load()
        let key = configuration.panel?.id ?? state.panels.first?.key
        let info = state.panels.first { $0.key == key }
        return PanelEntry(date: Date(),
                          title: configuration.panel?.title ?? info?.title ?? "Status Board",
                          kind: info?.kind ?? .bridge,
                          record: key.flatMap { state.records[$0] })
    }
}

// MARK: - Views

struct PanelWidgetEntryView: View {
    let entry: PanelEntry
    @Environment(\.widgetFamily) private var family

    /// The panel's headline value, for the compact accessory families.
    var summaryValue: String {
        switch entry.record?.snapshot {
        case .number(let value, let unit):
            let text = value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(format: "%.1f", value)
            return unit.map { "\(text) \($0)" } ?? text
        case .series(let series):
            if let last = series.points.last {
                let text = String(format: "%.1f", last.value)
                return series.unit.map { "\(text) \($0)" } ?? text
            }
            return "—"
        case .text(let text):
            return String(text.prefix(30))
        case .statuses(let statuses):
            let down = statuses.filter { $0.state == .down }.count
            return down == 0 ? "All up" : "\(down) down"
        case .weather(let report):
            return "\(Int(report.temperatureC.rounded()))°"
        case .feed(let items):
            return items.first?.title ?? "—"
        default:
            return "—"
        }
    }

    var gaugeFraction: Double? {
        if case .number(let value, _) = entry.record?.snapshot,
           value >= 0, value <= 100 {
            return value / 100
        }
        return nil
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("\(entry.title): \(summaryValue)")

            case .accessoryCircular:
                if let fraction = gaugeFraction {
                    Gauge(value: fraction) {
                        Text(entry.title.prefix(3).uppercased())
                    } currentValueLabel: {
                        Text(summaryValue.split(separator: " ").first.map(String.init) ?? "—")
                    }
                    .gaugeStyle(.accessoryCircular)
                } else {
                    VStack(spacing: 0) {
                        Image(systemName: entry.kind.symbolName)
                            .font(.system(size: 13, weight: .bold))
                        Text(summaryValue.split(separator: " ").first.map(String.init) ?? "—")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                    .widgetAccentable()
                }

            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: entry.kind.symbolName)
                            .font(.system(size: 10, weight: .bold))
                        Text(entry.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .widgetAccentable()
                    Text(summaryValue)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            default:
                fullPanel
            }
        }
        .containerBackground(for: .widget) {
            SBTheme.background
        }
    }

    var fullPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: entry.kind.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SBTheme.accent)
                Text(entry.title.uppercased())
                    .font(SBTheme.titleFont(size: 10))
                    .foregroundStyle(SBTheme.textSecondary)
                    .kerning(1)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            SnapshotContentView(record: entry.record, settings: PanelSettings())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Widget definition

struct StatusBoardPanelWidget: Widget {
    let kind = "StatusBoardPanelWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectPanelIntent.self,
                               provider: PanelTimelineProvider()) { entry in
            PanelWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Status Board Panel")
        .description("Shows live data from one of your Status Board panels.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryInline, .accessoryCircular, .accessoryRectangular])
        #elseif os(watchOS)
        .supportedFamilies([.accessoryInline, .accessoryCircular,
                            .accessoryRectangular, .accessoryCorner])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

@main
struct StatusBoardWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusBoardPanelWidget()
        #if os(iOS)
        PanelLiveActivityWidget()
        OpenStatusBoardControl()
        #endif
    }
}
