import WidgetKit
import SwiftUI
import AppIntents
import StatusBoardKit

// MARK: - Configuration intent

/// A board, as offered by the widget's "Board" row.
struct BoardEntity: AppEntity {
    var id: String
    var name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Board"
    static let defaultQuery = BoardEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ info: WidgetBoardInfo) {
        self.init(id: info.id, name: info.name)
    }
}

struct BoardEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BoardEntity] {
        WidgetSharedState.load().boards
            .filter { identifiers.contains($0.id) }
            .map(BoardEntity.init)
    }

    func suggestedEntities() async throws -> [BoardEntity] {
        WidgetSharedState.load().boards.map(BoardEntity.init)
    }

    func defaultResult() async -> BoardEntity? {
        try? await suggestedEntities().first
    }
}

/// A panel — one data source on a board — as offered by the widget's "Panel" row.
struct PanelEntity: AppEntity {
    /// The panel's identity, not its snapshot key: boards can share a bridge
    /// key, and the widget has to come back to the one that was picked.
    var id: String
    var title: String
    var boardName: String
    var kindName: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Panel"
    static let defaultQuery = PanelEntityQuery()

    /// The subtitle names the board, which is what tells two panels of the
    /// same name apart when the picker is showing every board at once.
    var displayRepresentation: DisplayRepresentation {
        let subtitle = boardName.isEmpty ? kindName : "\(boardName) · \(kindName)"
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ info: WidgetPanelInfo) {
        id = info.panelID
        title = info.title
        boardName = info.boardName
        kindName = info.kind.displayName
    }
}

struct PanelEntityQuery: EntityQuery {
    /// Narrows the panel list to the board chosen a row above it, so the edit
    /// screen reads the way the app does: pick the board, then the data source.
    @IntentParameterDependency<SelectPanelIntent>(\.$board)
    var selection

    func entities(for identifiers: [String]) async throws -> [PanelEntity] {
        let state = WidgetSharedState.load()
        return identifiers.compactMap { identifier in
            state.panels.first { $0.panelID == identifier }
                // Widgets configured before boards were mirrored stored the
                // snapshot key. Resolve those rather than drop the choice.
                ?? state.panels.first { $0.key == identifier }
        }
        .map(PanelEntity.init)
    }

    func suggestedEntities() async throws -> [PanelEntity] {
        let state = WidgetSharedState.load()
        return state.panels(onBoard: selection?.board.id).map(PanelEntity.init)
    }

    func defaultResult() async -> PanelEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectPanelIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Panel"
    static let description = IntentDescription("Choose which board and which of its panels to display.")

    @Parameter(title: "Board")
    var board: BoardEntity?

    @Parameter(title: "Panel")
    var panel: PanelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$panel) from \(\.$board)")
    }
}

// MARK: - Timeline

struct PanelEntry: TimelineEntry {
    let date: Date
    let title: String
    let kind: PanelKind
    let record: SnapshotRecord?
    /// The panel's settings, mirrored alongside its data — a complication has
    /// to know whether the board reads in Celsius or Fahrenheit, and which
    /// question a home panel was asking.
    var settings = PanelSettings()
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
    /// Complication gallery choices on the watch: one per panel. Each carries
    /// its board too, so editing one on the watch opens on the right board.
    func recommendations() -> [AppIntentRecommendation<SelectPanelIntent>] {
        let state = WidgetSharedState.load()
        let showsBoard = state.boards.count > 1
        return state.panels.prefix(8).map { info in
            let intent = SelectPanelIntent()
            intent.board = BoardEntity(id: info.boardID, name: info.boardName)
            intent.panel = PanelEntity(info)
            let label = showsBoard && !info.boardName.isEmpty
                ? "\(info.boardName) · \(info.title)"
                : info.title
            return AppIntentRecommendation(intent: intent, description: Text(label))
        }
    }
    #endif

    private func entry(for configuration: SelectPanelIntent) -> PanelEntry {
        let state = WidgetSharedState.load()
        let info = state.panel(id: configuration.panel?.id, onBoard: configuration.board?.id)
        return PanelEntry(date: Date(),
                          // The live mirror wins over the configuration, so a
                          // renamed panel renames on the widget too.
                          title: info?.title ?? configuration.panel?.title ?? "Status Board",
                          kind: info?.kind ?? .bridge,
                          record: info.flatMap { state.records[$0.key] },
                          settings: info?.settings ?? PanelSettings())
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
        case .vehicle(let vehicle):
            // On a Lock Screen there is room for one fact, so it is whichever
            // the car's own state makes urgent.
            if vehicle.isDriving, let speed = vehicle.drive.speedMPH {
                return TessieReadout.speed(speed, units: vehicle.units)
            }
            if let level = vehicle.battery.level {
                return vehicle.isCharging
                    ? "\(Int(level.rounded()))% ⚡"
                    : "\(Int(level.rounded()))%"
            }
            return vehicle.connection.displayName
        case .homeSensors(let report):
            return HomeReadout.compactSummary(report: report, settings: entry.settings)
        case .thermostat(let readout):
            return HomeReadout.compactSummary(thermostat: readout, settings: entry.settings)
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
            SnapshotContentView(record: entry.record, settings: entry.settings)
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
