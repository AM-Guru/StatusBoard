import SwiftUI

/// The home panels.
///
/// Three providers land on two snapshot shapes, so there are two renderers
/// here and both are provider-blind: a HomeKit thermostat, a Home Assistant
/// climate entity and a Nest unit draw identically, which is the point of
/// normalizing in the sources. The panel's *mode* picks the layout.

// MARK: - Shared colors

extension HomeReading.Tone {
    /// The panel-aware variant, for the same reason `ServiceStatus.State` has
    /// one: semantic colors darken on a light theme.
    func color(in style: SBPanelStyle) -> Color {
        switch self {
        case .neutral: return style.textPrimary
        case .good: return style.good
        case .warn: return style.warn
        case .bad: return style.bad
        }
    }
}

extension HVACIssue.Severity {
    func color(in style: SBPanelStyle) -> Color {
        switch self {
        case .info: return style.textSecondary
        case .notice: return style.accent
        case .warning: return style.warn
        case .critical: return style.bad
        }
    }

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .notice: return "lightbulb"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

extension HVACStatus {
    func color(in style: SBPanelStyle) -> Color {
        switch self {
        case .heating: return style.bad
        case .cooling: return Color(hex: 0x4AA8FF)
        case .fan: return style.accent
        case .off, .unknown: return style.textSecondary
        }
    }
}

// MARK: - Sensors

/// Rooms, sensors and activity — one renderer, because they differ only in
/// what the source put in the report.
struct HomeSensorsPanelView: View {
    let report: HomeSensorReport
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style

    private var units: WeatherUnits { settings.weatherUnits }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.homeMode == .activity {
                HomeActivityList(report: report, settings: settings)
            } else {
                HomeRoomGrid(report: report, settings: settings)
            }
            if let note = report.note {
                Text(note)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Rooms as tiles: the room's name, its temperature large, and whatever else
/// it reports small underneath.
struct HomeRoomGrid: View {
    let report: HomeSensorReport
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style
    @Environment(\.panelAccent) private var accent

    private var units: WeatherUnits { settings.weatherUnits }

    var body: some View {
        GeometryReader { proxy in
            let columns = max(1, min(4, Int(proxy.size.width / 110)))
            let grid = Array(repeating: GridItem(.flexible(), spacing: 8), count: columns)
            ScrollView(.vertical) {
                LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                    ForEach(report.byRoom, id: \.room) { group in
                        roomTile(group.room, readings: group.readings)
                    }
                }
            }
            .scrollDisabledIfStatic()
        }
    }

    @ViewBuilder
    private func roomTile(_ room: String, readings: [HomeReading]) -> some View {
        // The headline is the temperature when there is one, because that is
        // what a room panel is for; otherwise the first reading stands in.
        let headline = readings.first { $0.kind == .temperature } ?? readings.first
        let rest = readings.filter { $0.id != headline?.id }

        VStack(alignment: .leading, spacing: 2) {
            Text(room.uppercased())
                .font(SBTheme.titleFont(size: 9))
                .kerning(1.1)
                .foregroundStyle(style.textSecondary)
                .lineLimit(1)
            if let headline {
                Text(headline.displayValue(units: units))
                    .font(SBTheme.lcdFont(size: 26))
                    .foregroundStyle(headline.kind == .temperature
                                     ? accent : headline.tone.color(in: style))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .opacity(headline.isReachable ? 1 : 0.45)
            }
            if !rest.isEmpty {
                HStack(spacing: 6) {
                    ForEach(rest.prefix(3)) { reading in
                        HomeReadingChip(reading: reading, units: units)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        // A room with no humidity reading is shorter than one that has it, and
        // a grid row centres its items — so without this the temperatures in a
        // row sit at three different heights.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Motion, doors and locks, newest-looking first: anything active floats to
/// the top, because a panel of thirty "Closed" rows buries the one that says
/// the back door is open.
struct HomeActivityList: View {
    let report: HomeSensorReport
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style

    private var ordered: [HomeReading] {
        report.readings.sorted { lhs, rhs in
            if (lhs.isActive == true) != (rhs.isActive == true) { return lhs.isActive == true }
            let left = lhs.updatedAt ?? .distantPast
            let right = rhs.updatedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(ordered) { reading in
                    HStack(spacing: 8) {
                        Image(systemName: reading.kind.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(reading.tone.color(in: style))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(reading.name)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(style.textPrimary)
                                .lineLimit(1)
                            if let room = reading.room {
                                Text(room)
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(style.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(reading.displayValue(units: settings.weatherUnits))
                            .font(SBTheme.titleFont(size: 11))
                            .foregroundStyle(reading.tone.color(in: style))
                    }
                    .padding(.vertical, 4)
                    .opacity(reading.isReachable ? 1 : 0.45)
                    Divider().overlay(style.separator)
                }
            }
        }
        .scrollDisabledIfStatic()
    }
}

/// A small "43%" or "Open" beside a room's headline.
struct HomeReadingChip: View {
    let reading: HomeReading
    let units: WeatherUnits

    @Environment(\.sbStyle) private var style

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: reading.kind.symbolName)
                .font(.system(size: 8, weight: .semibold))
            Text(reading.displayValue(units: units))
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(reading.tone.color(in: style))
        .lineLimit(1)
    }
}

// MARK: - Thermostat

/// The thermostat panel, in three layouts: the reading, the trend, and the
/// equipment's health. They share a header so a board with all three on it
/// reads as one instrument rather than three.
struct ThermostatPanelView: View {
    let readout: ThermostatReadout
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style
    @Environment(\.panelAccent) private var accent

    private var units: WeatherUnits { settings.weatherUnits }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch settings.homeMode {
            case .trend:
                HVACTrendView(readout: readout, settings: settings)
                trendFooter
            case .diagnostics:
                HVACDiagnosticsView(readout: readout, settings: settings)
            default:
                summary
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(readout.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(style.textPrimary)
                .lineLimit(1)
            if readout.status.isConditioning || readout.status == .fan {
                HomeBadge(text: readout.status.displayName.uppercased(),
                          symbol: readout.status.symbolName,
                          color: readout.status.color(in: style))
            } else if let hold = readout.holdLabel {
                HomeBadge(text: hold.uppercased(), symbol: "leaf.fill", color: style.good)
            } else if readout.mode == .off {
                HomeBadge(text: "OFF", symbol: "power", color: style.textSecondary)
            }
            Spacer(minLength: 0)
            if !readout.isOnline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(style.warn)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Summary layout

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("NOW")
                        .font(SBTheme.titleFont(size: 9))
                        .kerning(1.2)
                        .foregroundStyle(style.textSecondary)
                    Text(readout.currentC.map { SBTemperature.short($0, units: units) } ?? "—")
                        .font(SBTheme.lcdFont(size: 40))
                        .foregroundStyle(accent)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if let setpoint = readout.setpointText(units: units) {
                        LabeledStat(label: "SET TO", value: setpoint, tint: style.textPrimary)
                    }
                    LabeledStat(label: "MODE", value: readout.mode.displayName,
                                tint: style.textPrimary, symbol: readout.mode.symbolName)
                }
            }

            HStack(spacing: 14) {
                if let humidity = readout.humidity {
                    HomeReadingChip(reading: HomeReading(id: "h", name: "Humidity",
                                                         kind: .humidity, value: humidity),
                                    units: units)
                }
                if let outdoor = readout.outdoorC {
                    HomeReadingChip(reading: HomeReading(id: "o", name: "Outside",
                                                         kind: .temperature, value: outdoor),
                                    units: units)
                }
                if let deviation = readout.deviationC, abs(deviation) >= 0.5 {
                    Text("\(deviation > 0 ? "+" : "−")\(SBTemperature.delta(abs(deviation), units: units)) vs set")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(style.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if settings.showsHomeRoomStrip, !otherRooms.isEmpty {
                HomeRoomStrip(readings: otherRooms, units: units)
            }
            if settings.showsHVACDiagnostics {
                HVACHealthLine(diagnostics: readout.diagnostics)
            }
        }
    }

    /// The thermostat's own room would just repeat the big number above it.
    private var otherRooms: [HomeReading] {
        readout.rooms.filter { reading in
            guard reading.kind == .temperature else { return false }
            if let room = readout.room, reading.room == room { return false }
            return reading.name != readout.name
        }
    }

    private var trendFooter: some View {
        HStack(spacing: 12) {
            TrendKey(color: accent, label: "Indoor", dashed: false)
            TrendKey(color: style.textSecondary, label: "Set to", dashed: true)
            Spacer(minLength: 0)
            if let diagnostics = readout.diagnostics, diagnostics.hasEnoughHistory {
                Text("\(diagnostics.cycles) cycles · \(Int((diagnostics.runtimeFraction * 100).rounded()))% runtime")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(style.textSecondary)
            }
        }
    }
}

/// The other rooms, as a single line under a thermostat.
struct HomeRoomStrip: View {
    let readings: [HomeReading]
    let units: WeatherUnits

    @Environment(\.sbStyle) private var style

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(readings.prefix(8)) { reading in
                    VStack(spacing: 0) {
                        Text(reading.displayValue(units: units))
                            .font(SBTheme.lcdFont(size: 15))
                            .foregroundStyle(style.textPrimary)
                        Text(reading.room ?? reading.name)
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(style.textSecondary)
                            .lineLimit(1)
                    }
                    .opacity(reading.isReachable ? 1 : 0.45)
                }
            }
        }
        .scrollDisabledIfStatic()
    }
}

struct LabeledStat: View {
    let label: String
    let value: String
    var tint: Color
    var symbol: String?

    @Environment(\.sbStyle) private var style

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(label)
                .font(SBTheme.titleFont(size: 8))
                .kerning(1.1)
                .foregroundStyle(style.textSecondary)
            HStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                }
                Text(value)
                    .font(SBTheme.lcdFont(size: 15))
            }
            .foregroundStyle(tint)
            .lineLimit(1)
        }
    }
}

struct HomeBadge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(SBTheme.titleFont(size: 8)).kerning(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
    }
}

struct TrendKey: View {
    let color: Color
    let label: String
    let dashed: Bool

    @Environment(\.sbStyle) private var style

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 12, height: 2)
                .opacity(dashed ? 0.6 : 1)
            Text(label)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(style.textSecondary)
        }
    }
}

// MARK: - Trend

/// Indoor temperature against the setpoint, with the equipment's runs shaded
/// underneath.
///
/// The runs are the reason this is a bespoke chart rather than a `.series`
/// snapshot through `SBChartCanvas`: the shape of the line only means
/// something next to when the system was actually on, and a generic line
/// chart cannot show two series and a state band at once.
struct HVACTrendView: View {
    let readout: ThermostatReadout
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style
    @Environment(\.panelAccent) private var accent

    private var samples: [HVACSample] { readout.samples }
    private var units: WeatherUnits { settings.weatherUnits }

    var body: some View {
        if samples.count < 2 {
            VStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 20))
                    .foregroundStyle(style.textSecondary)
                Text("Recording — the chart fills in as readings arrive.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(style.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Canvas { context, size in
                draw(context: &context, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
    }

    private struct Scale {
        var start: Date
        var span: TimeInterval
        var low: Double
        var high: Double
        var plot: CGRect

        func x(_ date: Date) -> CGFloat {
            guard span > 0 else { return plot.minX }
            return plot.minX + plot.width * CGFloat(date.timeIntervalSince(start) / span)
        }

        func y(_ value: Double) -> CGFloat {
            guard high > low else { return plot.midY }
            return plot.maxY - plot.height * CGFloat((value - low) / (high - low))
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        // Room on the left for two temperature labels, and a strip at the
        // bottom for the run bands.
        let plot = CGRect(x: 30, y: 6, width: max(10, size.width - 36),
                          height: max(10, size.height - 24))
        let temperatures = samples.compactMap(\.indoorC) + samples.compactMap(\.targetC)
        guard let rawLow = temperatures.min(), let rawHigh = temperatures.max(),
              let first = samples.first, let last = samples.last else { return }
        // A flat day would otherwise draw a line of infinite thickness.
        let padding = max(0.5, (rawHigh - rawLow) * 0.15)
        let scale = Scale(start: first.date,
                          span: max(1, last.date.timeIntervalSince(first.date)),
                          low: rawLow - padding, high: rawHigh + padding, plot: plot)

        drawRunBands(context: &context, scale: scale, size: size)
        drawGrid(context: &context, scale: scale)
        drawSeries(context: &context, scale: scale,
                   values: samples.map { ($0.date, $0.targetC) },
                   color: style.textSecondary.opacity(0.9), width: 1.2, dashed: true)
        drawSeries(context: &context, scale: scale,
                   values: samples.map { ($0.date, $0.indoorC) },
                   color: accent, width: 2, dashed: false)
        drawLabels(context: &context, scale: scale, size: size)
    }

    /// Contiguous heating/cooling stretches, as a wash behind the lines and a
    /// solid bar along the bottom. The bar is what makes a two-minute run
    /// visible at all — a wash that thin reads as noise.
    private func drawRunBands(context: inout GraphicsContext, scale: Scale, size: CGSize) {
        let barY = scale.plot.maxY + 2
        var index = 0
        while index < samples.count {
            let status = samples[index].status
            guard status.isConditioning else { index += 1; continue }
            var end = index
            while end + 1 < samples.count && samples[end + 1].status == status { end += 1 }
            // A run's last sample marks when it was still on, so the band ends
            // at the following sample — otherwise every run draws one interval
            // short and a two-sample run has no width at all.
            let stop = end + 1 < samples.count ? samples[end + 1].date : samples[end].date
            let x0 = scale.x(samples[index].date)
            let x1 = max(x0 + 1, scale.x(stop))
            let color = status.color(in: style)
            // The wash stays faint: a system cycling forty times turns the
            // whole plot into stripes otherwise, and the line is the point.
            context.fill(Path(CGRect(x: x0, y: scale.plot.minY,
                                     width: x1 - x0, height: scale.plot.height)),
                         with: .color(color.opacity(0.09)))
            context.fill(Path(CGRect(x: x0, y: barY, width: x1 - x0, height: 5)),
                         with: .color(color.opacity(0.9)))
            index = end + 1
        }
    }

    private func drawGrid(context: inout GraphicsContext, scale: Scale) {
        var path = Path()
        for fraction in [0.0, 0.5, 1.0] {
            let y = scale.plot.minY + scale.plot.height * fraction
            path.move(to: CGPoint(x: scale.plot.minX, y: y))
            path.addLine(to: CGPoint(x: scale.plot.maxX, y: y))
        }
        context.stroke(path, with: .color(style.separator.opacity(0.5)), lineWidth: 0.5)
    }

    private func drawSeries(context: inout GraphicsContext, scale: Scale,
                            values: [(Date, Double?)], color: Color,
                            width: CGFloat, dashed: Bool) {
        var path = Path()
        var isDown = false
        for (date, value) in values {
            guard let value else {
                // A gap in the data breaks the line rather than being bridged
                // across, which would invent readings that never happened.
                isDown = false
                continue
            }
            let point = CGPoint(x: scale.x(date), y: scale.y(value))
            if isDown {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                isDown = true
            }
        }
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                          dash: dashed ? [3, 3] : []))
    }

    private func drawLabels(context: inout GraphicsContext, scale: Scale, size: CGSize) {
        func label(_ text: String, at point: CGPoint, anchor: UnitPoint) {
            context.draw(Text(text)
                .font(.system(size: 8, design: .rounded))
                .foregroundColor(style.textSecondary),
                         at: point, anchor: anchor)
        }
        label(SBTemperature.short(scale.high, units: units),
              at: CGPoint(x: 26, y: scale.plot.minY + 4), anchor: .trailing)
        label(SBTemperature.short(scale.low, units: units),
              at: CGPoint(x: 26, y: scale.plot.maxY - 4), anchor: .trailing)

        let formatter = DateFormatter()
        formatter.dateFormat = readout.samples.first.map {
            Date().timeIntervalSince($0.date) > 36 * 3600 ? "E ha" : "ha"
        } ?? "ha"
        if let first = samples.first, let last = samples.last {
            label(formatter.string(from: first.date),
                  at: CGPoint(x: scale.plot.minX, y: size.height - 5), anchor: .leading)
            label(formatter.string(from: last.date),
                  at: CGPoint(x: scale.plot.maxX, y: size.height - 5), anchor: .trailing)
        }
    }
}

// MARK: - Diagnostics

/// A single line under a thermostat: what the equipment's health amounts to.
struct HVACHealthLine: View {
    let diagnostics: HVACDiagnostics?

    @Environment(\.sbStyle) private var style

    var body: some View {
        let headline = HomeReadout.healthHeadline(diagnostics)
        HStack(spacing: 5) {
            Image(systemName: diagnostics?.issues.first?.severity.symbolName
                  ?? "checkmark.circle")
                .font(.system(size: 9, weight: .semibold))
            Text(headline.text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(headline.severity == .info && diagnostics?.issues.isEmpty != false
                         ? style.textSecondary
                         : headline.severity.color(in: style))
    }
}

/// The full equipment-health panel: the numbers, then anything wrong.
struct HVACDiagnosticsView: View {
    let readout: ThermostatReadout
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style

    private var diagnostics: HVACDiagnostics? { readout.diagnostics }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let diagnostics, diagnostics.hasEnoughHistory {
                statsRow(diagnostics)
                Divider().overlay(style.separator)
                issues(diagnostics)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watching the system")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(style.textPrimary)
                    Text("Cycling and runtime need about an hour of readings before they mean anything. \(diagnostics?.sampleCount ?? 0) so far.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(style.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func statsRow(_ diagnostics: HVACDiagnostics) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat("CYCLES/H", String(format: "%.1f", diagnostics.cyclesPerHour))
            stat("AVG RUN", diagnostics.averageRunMinutes.map {
                "\(Int($0.rounded()))m"
            } ?? "—")
            stat("RUNTIME", "\(Int((diagnostics.runtimeFraction * 100).rounded()))%")
            stat(diagnostics.coolingMinutes >= diagnostics.heatingMinutes ? "COOLING" : "HEATING",
                 HVACAnalyzer.minutes(max(diagnostics.coolingMinutes, diagnostics.heatingMinutes)))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(SBTheme.titleFont(size: 8))
                .kerning(1)
                .foregroundStyle(style.textSecondary)
            Text(value)
                .font(SBTheme.lcdFont(size: 18))
                .foregroundStyle(style.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func issues(_ diagnostics: HVACDiagnostics) -> some View {
        if diagnostics.issues.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(style.good)
                Text("Running normally over the last \(HVACAnalyzer.hours(diagnostics.windowHours)).")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(style.textSecondary)
            }
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diagnostics.issues) { issue in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Image(systemName: issue.severity.symbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(issue.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(issue.severity.color(in: style))
                            Text(issue.detail)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(style.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .scrollDisabledIfStatic()
        }
    }
}

// MARK: - HomeKit camera

/// A live HomeKit camera.
///
/// HomeKit hands cameras over as a view, not as image data: `HMCameraView` is
/// the only way to see one, and there is no API that returns the frames. So
/// unlike the Home Assistant camera panel — which fetches a JPEG and works
/// everywhere, including tvOS through a snapshot — this one is a real
/// UIKit view embedded in the panel, and it only exists where HomeKit and
/// UIKit both do.
struct HomeKitCameraPanelView: View {
    let panel: Panel

    @Environment(\.sbStyle) private var style
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        #if canImport(HomeKit) && canImport(UIKit) && !os(watchOS)
        if isStaticRender {
            // Poster exports and widget renders have no live stream; showing
            // the placeholder is honest and keeps the export deterministic.
            placeholder("Live view", symbol: "video.fill")
        } else {
            HomeKitCameraStream(accessoryID: panel.settings.homeTarget,
                                homeName: panel.settings.homeName)
        }
        #else
        placeholder("HomeKit camera views need an iPhone, iPad or Apple TV.",
                    symbol: "video.slash")
        #endif
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(style.textSecondary)
            Text(text)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(style.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }
}

// MARK: - Helpers

extension View {
    /// Scroll views inside a poster export or a widget must not scroll —
    /// and on tvOS an unfocusable scroll view swallows focus from the panels
    /// around it.
    @ViewBuilder
    func scrollDisabledIfStatic() -> some View {
        #if os(tvOS)
        self.scrollDisabled(true)
        #else
        self.modifier(StaticScrollDisable())
        #endif
    }
}

private struct StaticScrollDisable: ViewModifier {
    @Environment(\.isStaticRender) private var isStaticRender

    func body(content: Content) -> some View {
        content.scrollDisabled(isStaticRender)
    }
}
