import SwiftUI

/// Renders a 0–1 fraction in any of the TerminalWidget-style progress
/// formats: bar, circle, watch, dots, stack, matrix, gradient.
public struct ProgressContentView: View {
    let fraction: Double
    let label: String
    let format: ProgressFormat

    @Environment(\.panelAccent) private var accent

    public init(fraction: Double, label: String, format: ProgressFormat) {
        self.fraction = min(1, max(0, fraction))
        self.label = label
        self.format = format
    }

    /// Derives the fraction from a raw snapshot number and panel settings.
    public init(value: Double, settings: PanelSettings) {
        let fraction: Double
        if let total = settings.progressTotal, total > 0 {
            fraction = value / total
        } else if value <= 1 {
            fraction = value
        } else {
            fraction = value / 100
        }
        self.init(fraction: fraction,
                  label: "\(Int((min(1, max(0, fraction)) * 100).rounded()))%",
                  format: settings.progressFormat)
    }

    public var body: some View {
        Group {
            switch format {
            case .bar: barView
            case .circle: circleView(ticks: 0)
            case .watch: circleView(ticks: 60)
            case .dots: cellsView(isDots: true)
            case .matrix: cellsView(isDots: false)
            case .stack: stackView
            case .gradient: gradientView
            }
        }
        .padding(12)
    }

    var percentText: some View {
        Text(label)
            .font(SBTheme.lcdFont(size: 22))
            .foregroundStyle(SBTheme.textPrimary)
            .contentTransition(.numericText())
    }

    // MARK: - Bar

    var barView: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            percentText
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SBTheme.panelBorder)
                    Capsule().fill(accent)
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 10)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Circle / watch

    func circleView(ticks: Int) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                if ticks > 0 {
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let radius = min(size.width, size.height) / 2 - 2
                        for tick in 0..<ticks {
                            let angle = Double(tick) / Double(ticks) * 2 * .pi - .pi / 2
                            let isLit = Double(tick) / Double(ticks) <= fraction
                            var path = Path()
                            path.move(to: CGPoint(x: center.x + (radius - 5) * cos(angle),
                                                  y: center.y + (radius - 5) * sin(angle)))
                            path.addLine(to: CGPoint(x: center.x + radius * cos(angle),
                                                     y: center.y + radius * sin(angle)))
                            context.stroke(path,
                                           with: .color(isLit ? accent : SBTheme.panelBorder),
                                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                    }
                } else {
                    Circle()
                        .stroke(SBTheme.panelBorder, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(accent,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                percentText
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Dots / matrix

    func cellsView(isDots: Bool) -> some View {
        GeometryReader { proxy in
            let columns = 10
            let rows = 3
            let total = columns * rows
            let filled = Int((fraction * Double(total)).rounded())
            let gap: CGFloat = 4
            let cellWidth = (proxy.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (proxy.size.height - 30 - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let side = max(3, min(cellWidth, cellHeight))
            VStack(spacing: 6) {
                percentText
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                Group {
                                    if isDots {
                                        Circle().fill(accent)
                                    } else {
                                        RoundedRectangle(cornerRadius: 2).fill(accent)
                                    }
                                }
                                .frame(width: side, height: side)
                                .opacity(index < filled ? 1 : 0.18)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Stack

    var stackView: some View {
        HStack(spacing: 14) {
            GeometryReader { proxy in
                let segments = 8
                let filled = Int((fraction * Double(segments)).rounded())
                let gap: CGFloat = 3
                let height = (proxy.size.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
                VStack(spacing: gap) {
                    ForEach((0..<segments).reversed(), id: \.self) { segment in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent)
                            .frame(height: max(2, height))
                            .opacity(segment < filled ? 1 : 0.18)
                    }
                }
            }
            .frame(maxWidth: 56)
            percentText
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Gradient

    var gradientView: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            percentText
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7).fill(SBTheme.panelBorder)
                    // Full-length gradient clipped to the fraction, so the
                    // colors stay put as progress moves (TerminalWidget-style).
                    LinearGradient(colors: [SBTheme.secondaryAccent, accent],
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(6, proxy.size.width * fraction))
                        }
                }
            }
            .frame(height: 14)
            Spacer(minLength: 0)
        }
    }
}
