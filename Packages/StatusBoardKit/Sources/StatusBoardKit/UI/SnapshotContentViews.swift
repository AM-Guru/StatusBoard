import SwiftUI

/// Renders any `DataSnapshot` adaptively — used directly by bridge and MCP
/// panels, and as building blocks by the specialized panel views.
public struct SnapshotContentView: View {
    let record: SnapshotRecord?
    let settings: PanelSettings
    var chartStyle: ChartStyle = .line

    public init(record: SnapshotRecord?, settings: PanelSettings) {
        self.record = record
        self.settings = settings
        self.chartStyle = settings.chartStyle
    }

    public var body: some View {
        switch record?.snapshot {
        case .none:
            WaitingView()
        case .text(let text):
            BigTextView(text: text)
        case .number(let value, let unit):
            BigNumberView(value: value, unit: unit ?? settings.unit)
        case .series(let series):
            SeriesChartView(series: series, style: chartStyle, baseline: settings.chartBase)
        case .table(let table):
            TableContentView(table: table, settings: settings)
        case .feed(let items):
            FeedContentView(items: items, display: settings.listDisplay)
        case .weather(let report):
            WeatherContentView(report: report)
        case .statuses(let statuses):
            StatusContentView(statuses: statuses)
        case .image(let data):
            SnapshotImageView(data: data, filterSpec: settings.imageFilter)
        case .grades(let grades):
            GradesPanelView(grades: grades, settings: settings)
        case .schedule(let classes):
            SchedulePanelView(classes: classes, settings: settings)
        case .assignments(let digest):
            AssignmentsPanelView(digest: digest, settings: settings)
        case .error(let message):
            ErrorView(message: message)
        }
    }
}

struct WaitingView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(SBTheme.textSecondary)
            Text("WAITING FOR DATA")
                .font(SBTheme.titleFont(size: 10))
                .foregroundStyle(SBTheme.textSecondary)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(SBTheme.warn)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(SBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public struct BigNumberView: View {
    let value: Double
    let unit: String?

    @Environment(\.panelAccent) private var accent

    public init(value: Double, unit: String?) {
        self.value = value
        self.unit = unit
    }

    var formatted: String {
        if abs(value) >= 1000 || value == value.rounded() {
            return value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatted)
                    .font(SBTheme.lcdFont(size: min(proxy.size.height * 0.6, proxy.size.width * 0.3)))
                    .foregroundStyle(accent)
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(SBTheme.titleFont(size: min(proxy.size.height * 0.2, 24)))
                        .foregroundStyle(SBTheme.textSecondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 8)
    }
}

struct BigTextView: View {
    let text: String
    var isMonospace = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(isMonospace
                      ? .system(size: 13, design: .monospaced)
                      : .system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(SBTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }
}

public struct SeriesChartView: View {
    let series: SeriesData
    let style: ChartStyle
    let baseline: Double?

    @Environment(\.panelAccent) private var accent

    public init(series: SeriesData, style: ChartStyle, baseline: Double? = nil) {
        self.series = series
        self.style = style
        self.baseline = baseline
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let last = series.points.last {
                HStack(spacing: 4) {
                    Text(last.value.formatted(.number.precision(.fractionLength(0...1))))
                        .font(SBTheme.lcdFont(size: 18))
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                    if let unit = series.unit {
                        Text(unit)
                            .font(SBTheme.titleFont(size: 11))
                            .foregroundStyle(SBTheme.textSecondary)
                    }
                }
            }
            SBChartCanvas(series: series, style: style, baseline: baseline)
        }
        .padding(10)
    }
}

struct TableContentView: View {
    let table: TableData
    var settings = PanelSettings()

    /// TerminalWidget's semantic status-coloring vocabulary.
    static func statusColor(for cell: String) -> Color? {
        switch cell.trimmingCharacters(in: .whitespaces).lowercased() {
        case "success", "pass", "passed", "ok", "up", "online":
            return SBTheme.good
        case "warning", "warn", "degraded", "pending":
            return SBTheme.warn
        case "fail", "failed", "error", "down", "offline":
            return SBTheme.bad
        case "building", "running", "in progress":
            return SBTheme.secondaryAccent
        default:
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if settings.tableHasHeader {
                    HStack(spacing: 14) {
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                            Text(column.uppercased())
                                .font(SBTheme.titleFont(size: 10))
                                .foregroundStyle(SBTheme.textSecondary)
                                .kerning(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    Rectangle().fill(SBTheme.accent.opacity(0.5)).frame(height: 1)
                        .padding(.horizontal, 10)
                }
                ForEach(Array(table.rows.prefix(50).enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 14) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(
                                    settings.tableStatusColoring
                                        ? (Self.statusColor(for: cell) ?? SBTheme.textPrimary)
                                        : SBTheme.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        settings.tableZebra && rowIndex.isMultiple(of: 2)
                            ? SBTheme.panelBorder.opacity(0.24)
                            : .clear)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct FeedContentView: View {
    let items: [FeedItem]
    var display: ListDisplayMode = .list

    var body: some View {
        switch display {
        case .list: listView
        case .ticker: TickerView(items: items)
        }
    }

    var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(20)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(SBTheme.textPrimary)
                            .lineLimit(2)
                        if let published = item.published {
                            Text(published, format: .relative(presentation: .named))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(SBTheme.secondaryAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    Divider().overlay(SBTheme.panelBorder.opacity(0.6))
                }
            }
        }
    }
}

/// The original Status Board "ticker" view: one big rotating item.
struct TickerView: View {
    let items: [FeedItem]

    @Environment(\.panelAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 6)) { context in
            let visible = Array(items.prefix(12))
            if visible.isEmpty {
                WaitingView()
            } else {
                let index = Int(context.date.timeIntervalSince1970 / 6) % visible.count
                let item = visible[index]
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)
                    Text(item.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(SBTheme.textPrimary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    if let published = item.published {
                        Text(published, format: .relative(presentation: .named))
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(SBTheme.secondaryAccent)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        ForEach(0..<visible.count, id: \.self) { dot in
                            Circle()
                                .fill(dot == index ? accent : SBTheme.panelBorder)
                                .frame(width: 5, height: 5)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.4),
                           value: index)
            }
        }
    }
}

struct StatusContentView: View {
    let statuses: [ServiceStatus]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(statuses) { status in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(status.state.color)
                            .frame(width: 10, height: 10)
                            .shadow(color: status.state.color.opacity(0.8), radius: 4)
                        Text(status.name)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(SBTheme.textPrimary)
                        Spacer()
                        if let latency = status.latencyMS {
                            Text("\(Int(latency)) ms")
                                .font(SBTheme.lcdFont(size: 12))
                                .foregroundStyle(SBTheme.textSecondary)
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

struct WeatherContentView: View {
    let report: WeatherReport

    var body: some View {
        ViewThatFits(in: .vertical) {
            fullLayout
            compactLayout
        }
        .padding(10)
    }

    var compactLayout: some View {
        HStack(spacing: 10) {
            Image(systemName: report.symbolName)
                .font(.system(size: 26))
                .symbolRenderingMode(.multicolor)
            Text(report.temperatureC, format: .measurement(width: .narrow,
                                                           usage: .weather,
                                                           numberFormatStyle: .number.precision(.fractionLength(0))))
                .font(SBTheme.lcdFont(size: 30))
                .foregroundStyle(SBTheme.textPrimary)
            Spacer(minLength: 0)
        }
    }

    var fullLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: report.symbolName)
                    .font(.system(size: 34))
                    .symbolRenderingMode(.multicolor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(report.temperatureC, format: .measurement(width: .narrow,
                                                                   usage: .weather,
                                                                   numberFormatStyle: .number.precision(.fractionLength(0))))
                        .font(SBTheme.lcdFont(size: 34))
                        .foregroundStyle(SBTheme.textPrimary)
                    Text(report.conditionDescription)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(SBTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if !report.days.isEmpty {
                HStack(spacing: 0) {
                    ForEach(report.days) { day in
                        VStack(spacing: 2) {
                            Text(day.dateLabel.uppercased())
                                .font(SBTheme.titleFont(size: 9))
                                .foregroundStyle(SBTheme.textSecondary)
                            Image(systemName: day.symbolName)
                                .font(.system(size: 13))
                                .symbolRenderingMode(.multicolor)
                            Text("\(Int(day.highC.rounded()))°")
                                .font(SBTheme.lcdFont(size: 12))
                                .foregroundStyle(SBTheme.textPrimary)
                            Text("\(Int(day.lowC.rounded()))°")
                                .font(SBTheme.lcdFont(size: 11))
                                .foregroundStyle(SBTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

struct SnapshotImageView: View {
    let data: Data
    var filterSpec: String?

    var processedData: Data {
        guard let spec = filterSpec, !spec.isEmpty,
              let filtered = SBImageFilter.apply(spec, to: data) else { return data }
        return filtered
    }

    var body: some View {
        let bytes = processedData
        GeometryReader { proxy in
            Group {
                #if os(macOS)
                if let image = NSImage(data: bytes) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ErrorView(message: "Could not decode image")
                }
                #else
                if let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ErrorView(message: "Could not decode image")
                }
                #endif
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }
}

extension Measurement<UnitTemperature> {
    init(celsius: Double) {
        self.init(value: celsius, unit: .celsius)
    }
}

extension Text {
    init(_ celsius: Double, format: Measurement<UnitTemperature>.FormatStyle) {
        self.init(Measurement(celsius: celsius), format: format)
    }
}
