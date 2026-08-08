import SwiftUI

/// Surface detail for the named themes. These are deterministic vector marks,
/// so they remain crisp on a Watch complication, a Retina Mac, and a 4K TV
/// without adding image assets or making CloudKit payloads larger.
struct SBThemeTextureView: View {
    let texture: SBThemeTexture
    let accent: Color
    let isLight: Bool
    var intensity: Double = 1

    var body: some View {
        GeometryReader { proxy in
            textureLayer(size: proxy.size)
                .opacity(min(1, max(0, intensity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func textureLayer(size: CGSize) -> some View {
        switch texture {
        case .none:
            Color.clear
        case .dashboard:
            pattern(size: size, kind: .dashboard)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [accent.opacity(0.16), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: min(42, size.height * 0.22))
                }
        case .glass:
            ZStack {
                LinearGradient(colors: [.white.opacity(0.24), .clear, accent.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0,
                               endRadius: max(40, max(size.width, size.height) * 0.8))
            }
        case .carbonWeave:
            pattern(size: size, kind: .carbon)
        case .slateGrain:
            pattern(size: size, kind: .grain)
        case .paperFiber:
            pattern(size: size, kind: .paper)
        case .terminalScanlines:
            pattern(size: size, kind: .terminal)
                .overlay {
                    RadialGradient(colors: [accent.opacity(0.08), .clear], center: .center,
                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                }
        case .blueprintGrid:
            pattern(size: size, kind: .blueprint)
        case .sunsetGlow:
            ZStack {
                RadialGradient(colors: [Color(hex: 0xFFB36A).opacity(0.28), .clear],
                               center: UnitPoint(x: 0.78, y: 0.84), startRadius: 0,
                               endRadius: max(60, max(size.width, size.height) * 0.62))
                pattern(size: size, kind: .horizon)
            }
        case .auroraRibbon:
            ZStack {
                LinearGradient(colors: [.clear, accent.opacity(0.22),
                                        Color.cyan.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blur(radius: 10)
                pattern(size: size, kind: .aurora)
            }
        case .nocturneStars:
            pattern(size: size, kind: .stars)
                .overlay {
                    RadialGradient(colors: [accent.opacity(0.12), .clear],
                                   center: .topTrailing, startRadius: 0,
                                   endRadius: max(size.width, size.height) * 0.7)
                }
        case .daybreakRays:
            pattern(size: size, kind: .rays)
                .overlay {
                    RadialGradient(colors: [Color.white.opacity(0.32), .clear],
                                   center: .topLeading, startRadius: 0,
                                   endRadius: max(size.width, size.height) * 0.8)
                }
        }
    }

    private enum PatternKind {
        case dashboard, carbon, grain, paper, terminal, blueprint
        case horizon, aurora, stars, rays
    }

    private func pattern(size: CGSize, kind: PatternKind) -> some View {
        Canvas { context, canvasSize in
            switch kind {
            case .dashboard:
                var hatch = Path()
                let step: CGFloat = 18
                var x: CGFloat = -canvasSize.height
                while x < canvasSize.width {
                    hatch.move(to: CGPoint(x: x, y: canvasSize.height))
                    hatch.addLine(to: CGPoint(x: x + canvasSize.height, y: 0))
                    x += step
                }
                context.stroke(hatch, with: .color(.white.opacity(0.025)), lineWidth: 1)

            case .carbon:
                let step: CGFloat = 12
                var first = Path()
                var second = Path()
                var x: CGFloat = -canvasSize.height
                while x < canvasSize.width + canvasSize.height {
                    first.move(to: CGPoint(x: x, y: 0))
                    first.addLine(to: CGPoint(x: x - canvasSize.height, y: canvasSize.height))
                    second.move(to: CGPoint(x: x + step / 2, y: 0))
                    second.addLine(to: CGPoint(x: x + step / 2 + canvasSize.height,
                                               y: canvasSize.height))
                    x += step
                }
                context.stroke(first, with: .color(.white.opacity(0.07)), lineWidth: 3)
                context.stroke(second, with: .color(.black.opacity(0.15)), lineWidth: 3)

            case .grain, .paper:
                let drawsPaper = {
                    if case .paper = kind { return true }
                    return false
                }()
                let area = max(1, canvasSize.width * canvasSize.height)
                let count = min(420, max(24, Int(area / (drawsPaper ? 500 : 700))))
                for index in 0..<count {
                    let x = sbNoise(index, drawsPaper ? 101 : 107) * canvasSize.width
                    let y = sbNoise(index, drawsPaper ? 109 : 113) * canvasSize.height
                    let length = drawsPaper ? 3 + sbNoise(index, 127) * 12 : 0.8
                    var mark = Path()
                    mark.move(to: CGPoint(x: x, y: y))
                    mark.addLine(to: CGPoint(x: x + length, y: y + (drawsPaper ? 0.5 : 0)))
                    let color = isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.045)
                    context.stroke(mark, with: .color(color), lineWidth: drawsPaper ? 0.5 : 1)
                }

            case .terminal:
                var lines = Path()
                var y: CGFloat = 1
                while y < canvasSize.height {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    y += 4
                }
                context.stroke(lines, with: .color(accent.opacity(0.075)), lineWidth: 1)

            case .blueprint:
                let step: CGFloat = 16
                var fine = Path()
                var heavy = Path()
                var x: CGFloat = 0
                var index = 0
                while x <= canvasSize.width {
                    let target = index.isMultiple(of: 5) ? heavy : fine
                    var line = target
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: canvasSize.height))
                    if index.isMultiple(of: 5) { heavy = line } else { fine = line }
                    x += step; index += 1
                }
                var y: CGFloat = 0
                index = 0
                while y <= canvasSize.height {
                    let target = index.isMultiple(of: 5) ? heavy : fine
                    var line = target
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    if index.isMultiple(of: 5) { heavy = line } else { fine = line }
                    y += step; index += 1
                }
                context.stroke(fine, with: .color(.white.opacity(0.055)), lineWidth: 0.5)
                context.stroke(heavy, with: .color(accent.opacity(0.13)), lineWidth: 1)

            case .horizon:
                var bands = Path()
                for index in 0..<4 {
                    let y = canvasSize.height * (0.58 + CGFloat(index) * 0.09)
                    bands.move(to: CGPoint(x: 0, y: y))
                    bands.addCurve(to: CGPoint(x: canvasSize.width, y: y + 5),
                                   control1: CGPoint(x: canvasSize.width * 0.3, y: y - 8),
                                   control2: CGPoint(x: canvasSize.width * 0.7, y: y + 10))
                }
                context.stroke(bands, with: .color(accent.opacity(0.13)), lineWidth: 1)

            case .aurora:
                for index in 0..<3 {
                    var ribbon = Path()
                    let y = canvasSize.height * (0.2 + CGFloat(index) * 0.22)
                    ribbon.move(to: CGPoint(x: -20, y: y))
                    ribbon.addCurve(to: CGPoint(x: canvasSize.width + 20, y: y + 10),
                                    control1: CGPoint(x: canvasSize.width * 0.25,
                                                      y: y + canvasSize.height * 0.25),
                                    control2: CGPoint(x: canvasSize.width * 0.7,
                                                      y: y - canvasSize.height * 0.2))
                    context.stroke(ribbon, with: .color(accent.opacity(0.10 - Double(index) * 0.02)),
                                   lineWidth: 5 + CGFloat(index) * 3)
                }

            case .stars:
                let count = min(180, max(18, Int(canvasSize.width * canvasSize.height / 1800)))
                for star in 0..<count {
                    let x = sbNoise(star, 151) * canvasSize.width
                    let y = sbNoise(star, 157) * canvasSize.height
                    let diameter = 0.7 + sbNoise(star, 163) * 1.4
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y,
                                                        width: diameter, height: diameter)),
                                 with: .color(.white.opacity(0.18 + sbNoise(star, 167) * 0.35)))
                }

            case .rays:
                let origin = CGPoint(x: 0, y: 0)
                let radius = hypot(canvasSize.width, canvasSize.height) * 1.2
                for ray in 0..<10 where ray.isMultiple(of: 2) {
                    let a = Double(ray) * .pi / 18
                    let b = Double(ray + 1) * .pi / 18
                    var wedge = Path()
                    wedge.move(to: origin)
                    wedge.addLine(to: CGPoint(x: cos(a) * radius, y: sin(a) * radius))
                    wedge.addLine(to: CGPoint(x: cos(b) * radius, y: sin(b) * radius))
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(accent.opacity(0.035)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Small theme-specific construction details around a panel. This stays subtle
/// enough for dense boards but makes Terminal, Blueprint, Glass, and the other
/// named looks read as different products rather than different paint colors.
struct SBThemePanelChrome: View {
    let theme: SBThemeName
    let accent: Color
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            switch theme {
            case .glass:
                LinearGradient(colors: [.white.opacity(0.34), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: min(34, proxy.size.height * 0.22))
            case .terminal:
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 2), style: .continuous)
                    .stroke(accent.opacity(0.16), lineWidth: 1)
                    .padding(3)
            case .blueprint:
                Canvas { context, size in
                    var marks = Path()
                    let length: CGFloat = 13
                    for point in [CGPoint(x: 6, y: 6), CGPoint(x: size.width - 6, y: 6),
                                  CGPoint(x: 6, y: size.height - 6),
                                  CGPoint(x: size.width - 6, y: size.height - 6)] {
                        let sx: CGFloat = point.x < size.width / 2 ? 1 : -1
                        let sy: CGFloat = point.y < size.height / 2 ? 1 : -1
                        marks.move(to: point)
                        marks.addLine(to: CGPoint(x: point.x + sx * length, y: point.y))
                        marks.move(to: point)
                        marks.addLine(to: CGPoint(x: point.x, y: point.y + sy * length))
                    }
                    context.stroke(marks, with: .color(accent.opacity(0.45)), lineWidth: 1)
                }
            case .paper:
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 2), style: .continuous)
                    .stroke(Color.black.opacity(0.07), lineWidth: 1)
                    .padding(3)
            case .carbon:
                LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.20)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
            case .sunset, .aurora, .nocturne, .daybreak:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(accent.opacity(0.12), lineWidth: 3)
                    .blur(radius: 3)
            case .board, .slate, .custom:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension SBThemeName {
    func panelTitleFont(size: CGFloat) -> Font {
        switch self {
        case .terminal:
            return .system(size: size, weight: .bold, design: .monospaced)
        case .paper, .daybreak:
            return .system(size: size, weight: .semibold, design: .serif)
        case .blueprint, .carbon:
            return .system(size: size, weight: .bold, design: .monospaced)
        default:
            return .system(size: size, weight: .bold, design: .rounded)
        }
    }

    var defaultPanelBorderWidth: CGFloat {
        switch self {
        case .terminal, .blueprint: return 1.5
        case .glass: return 0.75
        default: return 1
        }
    }
}
