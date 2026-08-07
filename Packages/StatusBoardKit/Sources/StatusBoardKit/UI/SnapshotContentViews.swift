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
            FeedContentView(items: items, display: settings.listDisplay,
                            showsIcons: settings.feedShowsSourceIcons,
                            showsSourceNames: settings.feedShowsSourceNames)
        case .weather(let report):
            WeatherContentView(report: report, settings: settings)
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
        case .vehicle(let vehicle):
            TessiePanelView(vehicle: vehicle, settings: settings)
        case .homeSensors(let report):
            HomeSensorsPanelView(report: report, settings: settings)
        case .thermostat(let readout):
            ThermostatPanelView(readout: readout, settings: settings)
        case .error(let message):
            ErrorView(message: message)
        }
    }
}

struct WaitingView: View {
    @Environment(\.sbStyle) private var sbStyle
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(sbStyle.textSecondary)
            Text("WAITING FOR DATA")
                .font(SBTheme.titleFont(size: 10))
                .foregroundStyle(sbStyle.textSecondary)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    @Environment(\.sbStyle) private var sbStyle
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(sbStyle.warn)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(sbStyle.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public struct BigNumberView: View {
    @Environment(\.sbStyle) private var sbStyle
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
                        .foregroundStyle(sbStyle.textSecondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 8)
    }
}

struct BigTextView: View {
    @Environment(\.sbStyle) private var sbStyle
    let text: String
    var isMonospace = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(isMonospace
                      ? .system(size: 13, design: .monospaced)
                      : .system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(sbStyle.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }
}

public struct SeriesChartView: View {
    @Environment(\.sbStyle) private var sbStyle
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
                            .foregroundStyle(sbStyle.textSecondary)
                    }
                }
            }
            SBChartCanvas(series: series, style: style, baseline: baseline)
        }
        .padding(10)
    }
}

struct TableContentView: View {
    @Environment(\.sbStyle) private var sbStyle
    let table: TableData
    var settings = PanelSettings()

    /// TerminalWidget's semantic status-coloring vocabulary.
    static func statusColor(for cell: String, in sbStyle: SBPanelStyle) -> Color? {
        switch cell.trimmingCharacters(in: .whitespaces).lowercased() {
        case "success", "pass", "passed", "ok", "up", "online":
            return sbStyle.good
        case "warning", "warn", "degraded", "pending":
            return sbStyle.warn
        case "fail", "failed", "error", "down", "offline":
            return sbStyle.bad
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
                                .foregroundStyle(sbStyle.textSecondary)
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
                                        ? (Self.statusColor(for: cell, in: sbStyle) ?? sbStyle.textPrimary)
                                        : sbStyle.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        settings.tableZebra && rowIndex.isMultiple(of: 2)
                            ? sbStyle.separator.opacity(0.24)
                            : .clear)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct FeedContentView: View {
    @Environment(\.sbStyle) private var sbStyle
    let items: [FeedItem]
    var display: ListDisplayMode = .list
    var showsIcons = true
    var showsSourceNames = true

    /// Naming the source on every row is only worth the space once a panel is
    /// merging more than one feed — otherwise it repeats itself.
    private var namesSources: Bool {
        showsSourceNames && Set(items.compactMap(\.sourceName)).count > 1
    }

    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        switch display {
        case .list: listView
        case .ticker:
            TickerView(items: items, showsIcons: showsIcons, showsSourceNames: namesSources)
        }
    }

    @ViewBuilder
    var listView: some View {
        // ImageRenderer rasterises a ScrollView's content as empty, so an
        // exported board would lose the headlines entirely.
        if isStaticRender {
            rows.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { rows }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.prefix(20)) { item in
                HStack(alignment: .top, spacing: 8) {
                    if showsIcons {
                        FeedSourceIcon(item: item, size: 18)
                            // Optically aligned with the first line of the
                            // headline rather than its box.
                            .padding(.top, 1)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(sbStyle.textPrimary)
                            .lineLimit(2)
                        if let byline = byline(for: item) {
                            Text(byline)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(SBTheme.secondaryAccent)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                Divider().overlay(sbStyle.separator.opacity(0.6))
            }
        }
    }

    /// "Ars Technica · 2 hours ago", dropping whichever half is missing.
    private func byline(for item: FeedItem) -> String? {
        var parts: [String] = []
        if namesSources, let source = item.sourceName, !source.isEmpty {
            parts.append(source)
        }
        if let published = item.published {
            parts.append(published.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A feed item's site icon: the publisher's favicon when the fetch found one,
/// otherwise a lettered chip whose colour is stable per source — so merged
/// feeds stay tellable apart even when a site serves no icon.
struct FeedSourceIcon: View {
    @Environment(\.sbStyle) private var sbStyle
    let item: FeedItem
    var size: CGFloat = 18

    private var label: String? {
        let name = item.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = (name?.isEmpty == false ? name : item.linkHost) ?? nil
        return fallback.flatMap { $0.first.map { String($0).uppercased() } }
    }

    /// Deterministic hue per source, so the same site keeps its colour across
    /// refreshes and devices.
    private var tint: Color {
        let seed = item.sourceName ?? item.linkHost ?? ""
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.85)
    }

    var body: some View {
        Group {
            if let data = item.sourceIcon, let image = Image(sbData: data) {
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let label {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(tint.opacity(0.85))
                    .overlay(
                        Text(label)
                            .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.75)))
            } else {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(sbStyle.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The original Status Board "ticker" view: one big rotating item.
struct TickerView: View {
    @Environment(\.sbStyle) private var sbStyle
    let items: [FeedItem]
    var showsIcons = true
    var showsSourceNames = true

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
                        .foregroundStyle(sbStyle.textPrimary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        if showsIcons {
                            FeedSourceIcon(item: item, size: 16)
                        }
                        if showsSourceNames, let source = item.sourceName, !source.isEmpty {
                            Text(source)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(sbStyle.textSecondary)
                                .lineLimit(1)
                        }
                        if let published = item.published {
                            Text(published, format: .relative(presentation: .named))
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(SBTheme.secondaryAccent)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        ForEach(0..<visible.count, id: \.self) { dot in
                            Circle()
                                .fill(dot == index ? accent : sbStyle.separator)
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
    @Environment(\.sbStyle) private var sbStyle
    let statuses: [ServiceStatus]
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        // ImageRenderer rasterises a ScrollView's content as empty, so an
        // exported board would lose this panel entirely. Drop the scrolling
        // wrapper when the board is being rendered to an image.
        if isStaticRender {
            list.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { list }
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(statuses) { status in
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.state.color(in: sbStyle))
                        .frame(width: 10, height: 10)
                        .shadow(color: status.state.color(in: sbStyle).opacity(0.8), radius: 4)
                    Text(status.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(sbStyle.textPrimary)
                    Spacer()
                    if let latency = status.latencyMS {
                        Text("\(Int(latency)) ms")
                            .font(SBTheme.lcdFont(size: 12))
                            .foregroundStyle(sbStyle.textSecondary)
                    }
                }
            }
        }
        .padding(10)
    }
}

struct WeatherContentView: View {
    @Environment(\.sbStyle) private var sbStyle
    let report: WeatherReport
    /// Carried so the panel can override the locale's temperature units and
    /// so the source line knows whether there is anything to say.
    var settings = PanelSettings()

    /// Celsius unless the panel says otherwise; `.automatic` keeps the
    /// locale-driven behaviour every existing board already has.
    private var temperatureStyle: Measurement<UnitTemperature>.FormatStyle {
        let digits = Measurement<UnitTemperature>.FormatStyle(
            width: .narrow, usage: settings.weatherUnits == .automatic ? .weather : .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(0)))
        return digits
    }

    private func temperature(_ celsius: Double) -> Measurement<UnitTemperature> {
        switch settings.weatherUnits {
        case .automatic, .celsius: return Measurement(value: celsius, unit: .celsius)
        case .fahrenheit: return Measurement(value: celsius, unit: .celsius).converted(to: .fahrenheit)
        }
    }

    /// Degrees only, for the compact five-day strip.
    private func degrees(_ celsius: Double) -> String {
        let value = settings.weatherUnits == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    var body: some View {
        // A wide panel gets the days down the right-hand side, where they can
        // be bigger than a strip squeezed underneath. Both axes are checked, so
        // a side-by-side is only taken when the panel really has the width for
        // it; anything narrower falls through to the stacked layouts, whose own
        // choice is a vertical one exactly as it was before.
        ViewThatFits(in: [.horizontal, .vertical]) {
            splitLayout(.large)
            splitLayout(.medium)
            splitLayout(.small)
            stackedLayouts
        }
        .padding(10)
    }

    private var stackedLayouts: some View {
        ViewThatFits(in: .vertical) {
            layout(.large)
            layout(.medium)
            layout(.small)
            compactLayout
        }
    }

    var compactLayout: some View {
        HStack(spacing: 10) {
            Image(systemName: report.symbolName)
                .font(.system(size: 26))
                .symbolRenderingMode(.multicolor)
            Text(temperature(report.temperatureC), format: temperatureStyle)
                .font(SBTheme.lcdFont(size: 30))
                .foregroundStyle(sbStyle.textPrimary)
            Spacer(minLength: 0)
        }
        .shadow(color: skyShadow, radius: 3, y: 1)
    }

    /// Conditions above, the five days in a strip underneath.
    private func layout(_ metrics: WeatherMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            nowBlock(metrics, symbol: metrics.nowSymbol, temperature: metrics.nowTemperature)
            if !report.days.isEmpty {
                dayStrip(metrics)
            }
        }
    }

    /// Conditions on the left, the five days listed down the right. Only ever
    /// chosen when the panel is wide enough to hold both.
    private func splitLayout(_ metrics: WeatherMetrics) -> some View {
        HStack(spacing: 16) {
            nowBlock(metrics, symbol: metrics.wideNowSymbol,
                     temperature: metrics.wideNowTemperature)
            // Wide enough for the two blocks to sit apart, not merely wide
            // enough for them both to exist — below that, stacking reads better.
            Spacer(minLength: 28)
            if !report.days.isEmpty {
                dayList(metrics)
            }
        }
    }

    private func nowBlock(_ metrics: WeatherMetrics, symbol: CGFloat,
                          temperature size: CGFloat) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.symbolName)
                .font(.system(size: symbol))
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 0) {
                Text(temperature(report.temperatureC), format: temperatureStyle)
                    .font(SBTheme.lcdFont(size: size))
                    .foregroundStyle(sbStyle.textPrimary)
                Text(report.conditionDescription)
                    .font(.system(size: metrics.condition, weight: .medium, design: .rounded))
                    .foregroundStyle(sbStyle.textPrimary.opacity(0.88))
                if let detail = detailLine {
                    Text(detail)
                        .font(.system(size: metrics.detail, weight: .medium, design: .rounded))
                        .foregroundStyle(sbStyle.textPrimary.opacity(0.72))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .shadow(color: skyShadow, radius: 3, y: 1)
    }

    /// One day per row. The columns are given widths from the type sizes rather
    /// than from their contents, so the days line up whatever the numbers are.
    private func dayList(_ metrics: WeatherMetrics) -> some View {
        VStack(spacing: metrics.rowGap) {
            ForEach(report.days) { day in
                HStack(spacing: metrics.rowGap + 4) {
                    Text(day.dateLabel.uppercased())
                        .font(SBTheme.titleFont(size: metrics.dayLabel))
                        .foregroundStyle(sbStyle.textPrimary.opacity(0.8))
                        .frame(width: metrics.dayLabel * 3.1, alignment: .leading)
                    Image(systemName: day.symbolName)
                        .font(.system(size: metrics.daySymbol))
                        .symbolRenderingMode(.multicolor)
                        .frame(width: metrics.daySymbol * 1.4)
                    Text(degrees(day.highC))
                        .font(SBTheme.lcdFont(size: metrics.dayHigh))
                        .foregroundStyle(sbStyle.textPrimary)
                        .frame(width: metrics.dayHigh * 2.4, alignment: .trailing)
                    Text(degrees(day.lowC))
                        .font(SBTheme.lcdFont(size: metrics.dayLow))
                        .foregroundStyle(sbStyle.textPrimary.opacity(0.72))
                        .frame(width: metrics.dayLow * 2.4, alignment: .trailing)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, metrics.dayPadding)
        .padding(.horizontal, metrics.dayPadding + 4)
        .background(dayPlate)
    }

    private func dayStrip(_ metrics: WeatherMetrics) -> some View {
        HStack(spacing: 0) {
            ForEach(report.days) { day in
                VStack(spacing: metrics.daySpacing) {
                    Text(day.dateLabel.uppercased())
                        .font(SBTheme.titleFont(size: metrics.dayLabel))
                        .foregroundStyle(sbStyle.textPrimary.opacity(0.8))
                    Image(systemName: day.symbolName)
                        .font(.system(size: metrics.daySymbol))
                        .symbolRenderingMode(.multicolor)
                    Text(degrees(day.highC))
                        .font(SBTheme.lcdFont(size: metrics.dayHigh))
                        .foregroundStyle(sbStyle.textPrimary)
                    Text(degrees(day.lowC))
                        .font(SBTheme.lcdFont(size: metrics.dayLow))
                        .foregroundStyle(sbStyle.textPrimary.opacity(0.72))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, metrics.dayPadding)
        .padding(.horizontal, metrics.dayPadding / 2)
        .background(dayPlate)
    }

    /// The forecast sits on a live sky that can be noon-bright or midnight
    /// black, and only the bottom-left corner of it is scrimmed. The strip
    /// carries its own backing so the five days read the same wherever the
    /// clouds happen to be.
    private var dayPlate: some View {
        let base = sbStyle.isLight ? Color.white : Color.black
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(base.opacity(sbStyle.isLight ? 0.42 : 0.38))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(sbStyle.textPrimary.opacity(0.12), lineWidth: 1)
            }
    }

    /// Lifts the unplated text off the sky behind it. Invisible on a light
    /// theme, where the text is dark to begin with.
    private var skyShadow: Color {
        sbStyle.isLight ? .clear : .black.opacity(0.55)
    }

    /// "Feels 21° · 64% · KSFO" — only the parts the source actually reported.
    private var detailLine: String? {
        var parts: [String] = []
        if let feels = report.feelsLikeC, abs(feels - report.temperatureC) >= 1 {
            parts.append("Feels \(degrees(feels))")
        }
        if let humidity = report.humidity {
            parts.append("\(Int(humidity.rounded()))%")
        }
        // The forecast provider is the unremarkable case; a station is not.
        if let source = report.sourceLabel, source != "Open-Meteo" {
            parts.append(source)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The type sizes one weather layout is made of.
///
/// A weather panel is usually given far more height than the forecast needs, so
/// the view offers three sizes and lets `ViewThatFits` take the largest the
/// panel can actually hold. `.small` is the size the panel drew at before this
/// existed, so nothing that fit then stops fitting now.
///
/// The `wide` sizes are for the side-by-side layout, where the conditions have
/// a column to themselves and can afford to be larger.
struct WeatherMetrics {
    var nowSymbol: CGFloat
    var nowTemperature: CGFloat
    var wideNowSymbol: CGFloat
    var wideNowTemperature: CGFloat
    var condition: CGFloat
    var detail: CGFloat
    var rowSpacing: CGFloat
    var dayLabel: CGFloat
    var daySymbol: CGFloat
    var dayHigh: CGFloat
    var dayLow: CGFloat
    var daySpacing: CGFloat
    var dayPadding: CGFloat
    /// Between the rows of the side-by-side day list.
    var rowGap: CGFloat

    static let large = WeatherMetrics(
        nowSymbol: 40, nowTemperature: 40, wideNowSymbol: 52, wideNowTemperature: 52,
        condition: 15, detail: 13, rowSpacing: 10,
        dayLabel: 13, daySymbol: 24, dayHigh: 20, dayLow: 17, daySpacing: 4,
        dayPadding: 9, rowGap: 6)

    static let medium = WeatherMetrics(
        nowSymbol: 34, nowTemperature: 34, wideNowSymbol: 42, wideNowTemperature: 42,
        condition: 13, detail: 11, rowSpacing: 8,
        dayLabel: 11, daySymbol: 18, dayHigh: 16, dayLow: 14, daySpacing: 3,
        dayPadding: 7, rowGap: 4)

    static let small = WeatherMetrics(
        nowSymbol: 30, nowTemperature: 30, wideNowSymbol: 32, wideNowTemperature: 32,
        condition: 12, detail: 10, rowSpacing: 2,
        dayLabel: 9, daySymbol: 13, dayHigh: 12, dayLow: 11, daySpacing: 2,
        dayPadding: 2, rowGap: 2)
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

extension Image {
    /// Decodes bytes carried inside a snapshot. Nil when they aren't an image
    /// this platform can read.
    init?(sbData data: Data) {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #endif
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
