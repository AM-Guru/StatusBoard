import SwiftUI

/// Immediate-mode chart renderer covering the full TerminalWidget-style
/// family. One Canvas, one style switch — no charting framework.
public struct SBChartCanvas: View {
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

    var values: [Double] { series.points.map(\.value) }

    public var body: some View {
        Canvas { context, size in
            guard values.count > 1 || (values.count == 1 && style == .bar) else {
                return
            }
            let scale = ChartScale(values: values, baseline: baseline)
            let plot = plotRect(in: size)
            drawGrid(context: &context, scale: scale, plot: plot)
            switch style {
            case .line: drawLine(context: &context, scale: scale, plot: plot, smooth: false)
            case .smooth: drawLine(context: &context, scale: scale, plot: plot, smooth: true)
            case .area: drawArea(context: &context, scale: scale, plot: plot)
            case .bar: drawBars(context: &context, scale: scale, plot: plot)
            case .lollipop: drawLollipop(context: &context, scale: scale, plot: plot)
            case .strip: drawStrip(context: &context, scale: scale, plot: plot)
            case .delta: drawDelta(context: &context, plot: plot)
            case .threshold: drawThreshold(context: &context, scale: scale, plot: plot)
            case .peak: drawPeak(context: &context, scale: scale, plot: plot)
            case .radial: drawRadial(context: &context, scale: scale, in: size)
            case .waveform: drawWaveform(context: &context, scale: scale, plot: plot)
            case .matrix: drawMatrix(context: &context, scale: scale, in: size)
            }
            drawXLabels(context: &context, plot: plot, size: size)
        }
    }

    // MARK: - Layout

    struct ChartScale {
        let min: Double
        let max: Double
        let base: Double

        init(values: [Double], baseline: Double?) {
            var lo = values.min() ?? 0
            var hi = values.max() ?? 1
            if let baseline {
                lo = Swift.min(lo, baseline)
                hi = Swift.max(hi, baseline)
            }
            if hi - lo < .ulpOfOne { hi = lo + 1 }
            self.min = lo
            self.max = hi
            self.base = baseline ?? lo
        }

        func unit(_ value: Double) -> Double {
            (value - min) / (max - min)
        }
    }

    var hasXLabels: Bool {
        series.points.contains { $0.label != nil && $0.date == nil }
    }

    private var usesGrid: Bool {
        switch style {
        case .line, .smooth, .area, .bar, .threshold, .delta, .peak, .lollipop, .strip:
            return true
        case .radial, .waveform, .matrix:
            return false
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        let trailingGutter: CGFloat = usesGrid ? 34 : 0
        let bottomGutter: CGFloat = hasXLabels ? 14 : 2
        return CGRect(x: 0, y: 4,
                      width: max(10, size.width - trailingGutter),
                      height: max(10, size.height - bottomGutter - 6))
    }

    private func x(_ index: Int, plot: CGRect) -> CGFloat {
        guard values.count > 1 else { return plot.midX }
        return plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1)
    }

    private func y(_ value: Double, scale: ChartScale, plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(scale.unit(value))
    }

    // MARK: - Chrome

    private func drawGrid(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        guard usesGrid else { return }
        for step in 0...2 {
            let fraction = Double(step) / 2
            let lineY = plot.maxY - plot.height * CGFloat(fraction)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: lineY))
            path.addLine(to: CGPoint(x: plot.maxX, y: lineY))
            context.stroke(path, with: .color(sbStyle.separator.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1))
            let value = scale.min + (scale.max - scale.min) * fraction
            let label = Text(compact(value))
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(sbStyle.textSecondary)
            context.draw(label, at: CGPoint(x: plot.maxX + 4, y: lineY),
                         anchor: .leading)
        }
    }

    private func drawXLabels(context: inout GraphicsContext, plot: CGRect, size: CGSize) {
        guard hasXLabels else { return }
        let labeled = series.points.enumerated().compactMap { index, point in
            point.label.map { (index, $0) }
        }
        guard !labeled.isEmpty else { return }
        let maxLabels = max(2, Int(plot.width / 60))
        let stride = max(1, labeled.count / maxLabels)
        for (index, label) in labeled.enumerated() where index % stride == 0 {
            let text = Text(label.1)
                .font(.system(size: 8, design: .rounded))
                .foregroundStyle(sbStyle.textSecondary)
            context.draw(text, at: CGPoint(x: x(label.0, plot: plot), y: size.height - 6),
                         anchor: .center)
        }
    }

    // MARK: - Styles

    private func linePath(scale: ChartScale, plot: CGRect, smooth: Bool) -> Path {
        var path = Path()
        let points = values.indices.map {
            CGPoint(x: x($0, plot: plot), y: y(values[$0], scale: scale, plot: plot))
        }
        guard let first = points.first else { return path }
        path.move(to: first)
        if smooth {
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: mid, control: previous)
            }
            if let last = points.last { path.addLine(to: last) }
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    private func drawLine(context: inout GraphicsContext, scale: ChartScale,
                          plot: CGRect, smooth: Bool) {
        context.stroke(linePath(scale: scale, plot: plot, smooth: smooth),
                       with: .color(accent),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func drawArea(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        var fill = linePath(scale: scale, plot: plot, smooth: true)
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(
            Gradient(colors: [accent.opacity(0.5), accent.opacity(0.02)]),
            startPoint: CGPoint(x: plot.midX, y: plot.minY),
            endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
        drawLine(context: &context, scale: scale, plot: plot, smooth: true)
    }

    private func barFrame(_ index: Int, scale: ChartScale, plot: CGRect) -> CGRect {
        let count = CGFloat(values.count)
        let gap = min(3, plot.width / count * 0.2)
        let width = max(1.5, plot.width / count - gap)
        let barX = plot.minX + plot.width * CGFloat(index) / count + gap / 2
        let valueY = y(values[index], scale: scale, plot: plot)
        let baseY = y(scale.base, scale: scale, plot: plot)
        return CGRect(x: barX, y: min(valueY, baseY),
                      width: width, height: max(2, abs(baseY - valueY)))
    }

    private func drawBars(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        for index in values.indices {
            let frame = barFrame(index, scale: scale, plot: plot)
            let radius = min(2.5, frame.width / 3)
            context.fill(Path(roundedRect: frame, cornerRadius: radius),
                         with: .color(accent))
        }
    }

    private func drawLollipop(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        let baseY = y(scale.base, scale: scale, plot: plot)
        for index in values.indices {
            let pointX = x(index, plot: plot)
            let pointY = y(values[index], scale: scale, plot: plot)
            var stem = Path()
            stem.move(to: CGPoint(x: pointX, y: baseY))
            stem.addLine(to: CGPoint(x: pointX, y: pointY))
            context.stroke(stem, with: .color(accent.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let dot = CGRect(x: pointX - 3.5, y: pointY - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(accent))
        }
    }

    private func drawStrip(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        for index in values.indices {
            let dot = CGRect(x: x(index, plot: plot) - 2.5,
                             y: y(values[index], scale: scale, plot: plot) - 2.5,
                             width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(accent))
        }
    }

    private func drawDelta(context: inout GraphicsContext, plot: CGRect) {
        let deltas = zip(values.dropFirst(), values).map(-)
        guard !deltas.isEmpty else { return }
        let magnitude = max(deltas.map(abs).max() ?? 1, .ulpOfOne)
        let midY = plot.midY
        let count = CGFloat(deltas.count)
        let gap = min(3, plot.width / count * 0.2)
        let width = max(1.5, plot.width / count - gap)
        var axis = Path()
        axis.move(to: CGPoint(x: plot.minX, y: midY))
        axis.addLine(to: CGPoint(x: plot.maxX, y: midY))
        context.stroke(axis, with: .color(sbStyle.textSecondary.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for (index, delta) in deltas.enumerated() {
            let height = max(2, plot.height / 2 * CGFloat(abs(delta) / magnitude))
            let barX = plot.minX + plot.width * CGFloat(index) / count + gap / 2
            let frame = CGRect(x: barX, y: delta >= 0 ? midY - height : midY,
                               width: width, height: height)
            context.fill(Path(roundedRect: frame, cornerRadius: min(2, width / 3)),
                         with: .color(delta >= 0 ? sbStyle.good : sbStyle.bad))
        }
    }

    private func drawThreshold(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        let limit = baseline ?? (scale.min + scale.max) / 2
        let limitY = y(limit, scale: scale, plot: plot)
        var rule = Path()
        rule.move(to: CGPoint(x: plot.minX, y: limitY))
        rule.addLine(to: CGPoint(x: plot.maxX, y: limitY))
        context.stroke(rule, with: .color(sbStyle.warn.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        context.stroke(linePath(scale: scale, plot: plot, smooth: false),
                       with: .color(sbStyle.textSecondary.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        for index in values.indices {
            let over = values[index] > limit
            let dot = CGRect(x: x(index, plot: plot) - 3,
                             y: y(values[index], scale: scale, plot: plot) - 3,
                             width: 6, height: 6)
            context.fill(Path(ellipseIn: dot),
                         with: .color(over ? sbStyle.bad : sbStyle.good))
        }
    }

    private func drawPeak(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        drawLine(context: &context, scale: scale, plot: plot, smooth: false)
        guard let peakValue = values.max(),
              let peakIndex = values.firstIndex(of: peakValue) else { return }
        let center = CGPoint(x: x(peakIndex, plot: plot),
                             y: y(peakValue, scale: scale, plot: plot))
        let halo = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        context.stroke(Path(ellipseIn: halo), with: .color(SBTheme.secondaryAccent),
                       style: StrokeStyle(lineWidth: 2))
        let label = Text(compact(peakValue))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(SBTheme.secondaryAccent)
        let anchorY: CGFloat = center.y < plot.minY + 14 ? 12 : -10
        context.draw(label, at: CGPoint(x: center.x, y: center.y + anchorY), anchor: .center)
    }

    private func drawRadial(context: inout GraphicsContext, scale: ChartScale, in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 6
        let innerRadius = maxRadius * 0.25
        for index in values.indices {
            let angle = Angle.degrees(Double(index) / Double(values.count) * 360 - 90)
            let radius = innerRadius + (maxRadius - innerRadius) * CGFloat(scale.unit(values[index]))
            var spoke = Path()
            spoke.move(to: CGPoint(x: center.x + innerRadius * cos(angle.radians),
                                   y: center.y + innerRadius * sin(angle.radians)))
            spoke.addLine(to: CGPoint(x: center.x + radius * cos(angle.radians),
                                      y: center.y + radius * sin(angle.radians)))
            let width = max(2, maxRadius * 0.9 / CGFloat(values.count) * 2)
            context.stroke(spoke, with: .color(accent.opacity(0.5 + 0.5 * scale.unit(values[index]))),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private func drawWaveform(context: inout GraphicsContext, scale: ChartScale, plot: CGRect) {
        let midY = plot.midY
        let count = CGFloat(values.count)
        let gap = min(2, plot.width / count * 0.25)
        let width = max(1.5, plot.width / count - gap)
        for index in values.indices {
            let half = max(1.5, plot.height / 2 * CGFloat(scale.unit(values[index])))
            let barX = plot.minX + plot.width * CGFloat(index) / count + gap / 2
            let frame = CGRect(x: barX, y: midY - half, width: width, height: half * 2)
            context.fill(Path(roundedRect: frame, cornerRadius: width / 2),
                         with: .color(accent.opacity(0.45 + 0.55 * scale.unit(values[index]))))
        }
    }

    private func drawMatrix(context: inout GraphicsContext, scale: ChartScale, in size: CGSize) {
        let count = values.count
        let aspect = size.width / max(size.height, 1)
        let columns = max(1, Int((Double(count) * aspect).squareRoot().rounded(.up)))
        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        let gap: CGFloat = 3
        let cellWidth = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for index in values.indices {
            let column = index % columns
            let row = index / columns
            let frame = CGRect(x: CGFloat(column) * (cellWidth + gap),
                               y: CGFloat(row) * (cellHeight + gap),
                               width: cellWidth, height: cellHeight)
            let intensity = scale.unit(values[index])
            context.fill(Path(roundedRect: frame, cornerRadius: min(3, cellWidth / 4)),
                         with: .color(accent.opacity(0.12 + 0.88 * intensity)))
        }
    }

    private func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 10_000 { return String(format: "%.0fk", value / 1000) }
        if magnitude >= 1000 { return String(format: "%.1fk", value / 1000) }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}
