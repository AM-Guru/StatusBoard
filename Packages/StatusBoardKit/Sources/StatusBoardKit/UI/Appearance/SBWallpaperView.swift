import SwiftUI

/// Deterministic pseudo-random in 0…1.
///
/// Every panel that masks a board wallpaper draws the *whole* wallpaper and
/// shows its own slice, so the drawing has to come out identical each time and
/// in each panel. A hash of the index does that; `Double.random` would not.
func sbNoise(_ index: Int, _ salt: Int = 0) -> Double {
    var value = UInt64(bitPattern: Int64(index &* 73_856_093 ^ salt &* 19_349_663))
    value ^= value >> 33
    value = value &* 0xFF51_AFD7_ED55_8CCD
    value ^= value >> 33
    value = value &* 0xC4CE_B9FE_1A85_EC53
    value ^= value >> 33
    return Double(value % 100_000) / 100_000
}

/// Draws a procedural board wallpaper at a given size.
///
/// The size is always the *board's* size, never the panel's — a panel masking
/// the backdrop draws this full-size and offsets it, which is what makes one
/// picture line up across several panels.
struct SBWallpaperView: View {
    let wallpaper: SBWallpaper
    let size: CGSize
    let tint: Color
    var animates: Bool = true

    var body: some View {
        switch wallpaper {
        case .none:
            Color.clear
        case .aurora:
            AuroraWallpaper(size: size, animates: animates)
        case .dusk:
            DuskWallpaper(size: size)
        case .grid:
            GridWallpaper(size: size, tint: tint)
        case .starfield:
            StarfieldWallpaper(size: size, animates: animates)
        case .topography:
            TopographyWallpaper(size: size, tint: tint)
        case .halftone:
            HalftoneWallpaper(size: size, tint: tint)
        }
    }
}

/// A slow, drifting mesh of color.
private struct AuroraWallpaper: View {
    let size: CGSize
    let animates: Bool

    private static let colors: [Color] = [
        Color(hex: 0x061A24), Color(hex: 0x0E3B44), Color(hex: 0x072230),
        Color(hex: 0x1C5E6B), Color(hex: 0x2FA88C), Color(hex: 0x0F3E52),
        Color(hex: 0x0A2436), Color(hex: 0x2C7A8C), Color(hex: 0x08161F),
    ]

    var body: some View {
        SBAnimatedCanvasHost(animates: animates, period: 1 / 20) { time in
            let phase = time * 0.08
            MeshGradient(width: 3, height: 3, points: Self.points(phase: phase),
                         colors: Self.colors, smoothsColors: true)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Corners stay pinned — only the edge midpoints and the center wander, or
    /// the mesh tears at the boundary.
    static func points(phase: Double) -> [SIMD2<Float>] {
        func wobble(_ base: SIMD2<Float>, _ index: Int, _ amount: Float) -> SIMD2<Float> {
            let a = Float(sin(phase + Double(index) * 1.7)) * amount
            let b = Float(cos(phase * 1.3 + Double(index) * 2.3)) * amount
            return SIMD2(min(1, max(0, base.x + a)), min(1, max(0, base.y + b)))
        }
        return [
            SIMD2(0, 0), wobble(SIMD2(0.5, 0), 1, 0.12), SIMD2(1, 0),
            wobble(SIMD2(0, 0.5), 2, 0.12), wobble(SIMD2(0.5, 0.5), 3, 0.22), wobble(SIMD2(1, 0.5), 4, 0.12),
            SIMD2(0, 1), wobble(SIMD2(0.5, 1), 5, 0.12), SIMD2(1, 1),
        ]
    }
}

/// A still evening sky with a low sun.
private struct DuskWallpaper: View {
    let size: CGSize

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x14173A), Color(hex: 0x4A2A55),
                                    Color(hex: 0xA8496A), Color(hex: 0xE8834E)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { context, canvasSize in
                let sun = CGPoint(x: canvasSize.width * 0.72, y: canvasSize.height * 0.74)
                let radius = min(canvasSize.width, canvasSize.height) * 0.16
                context.fill(
                    Path(ellipseIn: CGRect(x: sun.x - radius * 2.4, y: sun.y - radius * 2.4,
                                           width: radius * 4.8, height: radius * 4.8)),
                    with: .radialGradient(
                        Gradient(colors: [Color(hex: 0xFFD08A).opacity(0.55), .clear]),
                        center: sun, startRadius: 0, endRadius: radius * 2.4))
                context.fill(
                    Path(ellipseIn: CGRect(x: sun.x - radius, y: sun.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(Color(hex: 0xFFE3B0)))
                // Two flat cloud bands, for depth against the sun.
                for band in 0..<2 {
                    let y = canvasSize.height * (0.52 + Double(band) * 0.16)
                    let height = canvasSize.height * 0.035
                    context.fill(
                        Path(roundedRect: CGRect(x: canvasSize.width * (band == 0 ? 0.08 : 0.4),
                                                 y: y, width: canvasSize.width * 0.46,
                                                 height: height),
                             cornerRadius: height / 2),
                        with: .color(Color(hex: 0x2A1B3D).opacity(0.45)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Engineering-paper rules.
private struct GridWallpaper: View {
    let size: CGSize
    let tint: Color

    var body: some View {
        Canvas { context, canvasSize in
            let step: CGFloat = 34
            var fine = Path()
            var heavy = Path()
            var index = 0
            var x: CGFloat = 0
            while x <= canvasSize.width {
                if index.isMultiple(of: 5) {
                    heavy.move(to: CGPoint(x: x, y: 0))
                    heavy.addLine(to: CGPoint(x: x, y: canvasSize.height))
                } else {
                    fine.move(to: CGPoint(x: x, y: 0))
                    fine.addLine(to: CGPoint(x: x, y: canvasSize.height))
                }
                x += step
                index += 1
            }
            index = 0
            var y: CGFloat = 0
            while y <= canvasSize.height {
                if index.isMultiple(of: 5) {
                    heavy.move(to: CGPoint(x: 0, y: y))
                    heavy.addLine(to: CGPoint(x: canvasSize.width, y: y))
                } else {
                    fine.move(to: CGPoint(x: 0, y: y))
                    fine.addLine(to: CGPoint(x: canvasSize.width, y: y))
                }
                y += step
                index += 1
            }
            context.stroke(fine, with: .color(tint.opacity(0.13)), lineWidth: 1)
            context.stroke(heavy, with: .color(tint.opacity(0.28)), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Slowly twinkling stars over a deep gradient.
private struct StarfieldWallpaper: View {
    let size: CGSize
    let animates: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x05070F), Color(hex: 0x0B1230), Color(hex: 0x11172E)],
                           startPoint: .top, endPoint: .bottom)
            SBAnimatedCanvasHost(animates: animates, period: 1 / 12) { time in
                Canvas { context, canvasSize in
                    let count = Int((canvasSize.width * canvasSize.height) / 2600)
                    for star in 0..<max(24, min(600, count)) {
                        let x = sbNoise(star, 11) * canvasSize.width
                        let y = sbNoise(star, 29) * canvasSize.height
                        let base = 0.4 + sbNoise(star, 41) * 1.5
                        let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * (0.5 + sbNoise(star, 53))
                                                                    + sbNoise(star, 67) * 6.28))
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: base, height: base)),
                            with: .color(.white.opacity(0.25 + 0.6 * twinkle)))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Contour lines, like a map.
private struct TopographyWallpaper: View {
    let size: CGSize
    let tint: Color

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width * 0.38, y: canvasSize.height * 0.45)
            let maxRadius = max(canvasSize.width, canvasSize.height) * 0.85
            let rings = 22
            for ring in 1...rings {
                let scale = Double(ring) / Double(rings)
                var path = Path()
                let steps = 240
                for step in 0...steps {
                    let theta = Double(step) / Double(steps) * 2 * .pi
                    // A few harmonics make the ring organic instead of round;
                    // the same harmonics at every radius keep them nested.
                    let wobble = 1
                        + 0.14 * sin(theta * 3 + 0.6)
                        + 0.09 * sin(theta * 5 - 1.2)
                        + 0.05 * sin(theta * 8 + 2.4)
                    let radius = maxRadius * scale * wobble * (0.35 + 0.65 * scale)
                    let point = CGPoint(x: center.x + cos(theta) * radius,
                                        y: center.y + sin(theta) * radius * 0.72)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
                let emphasis = ring.isMultiple(of: 5) ? 0.34 : 0.16
                context.stroke(path, with: .color(tint.opacity(emphasis)),
                               lineWidth: ring.isMultiple(of: 5) ? 1.6 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A printed-dot gradient.
private struct HalftoneWallpaper: View {
    let size: CGSize
    let tint: Color

    var body: some View {
        Canvas { context, canvasSize in
            let step: CGFloat = 18
            var y: CGFloat = step / 2
            var row = 0
            while y < canvasSize.height + step {
                var x: CGFloat = (row.isMultiple(of: 2) ? step / 2 : step)
                while x < canvasSize.width + step {
                    let across = x / max(1, canvasSize.width)
                    let down = y / max(1, canvasSize.height)
                    let weight = max(0, 1 - (across * 0.7 + down * 0.5))
                    let radius = step * 0.46 * weight
                    if radius > 0.3 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                   width: radius * 2, height: radius * 2)),
                            with: .color(tint.opacity(0.35)))
                    }
                    x += step
                }
                y += step
                row += 1
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Wraps content that wants a clock, and hands it a *seconds* value.
///
/// Reduce Motion and static rendering both collapse this to a fixed instant,
/// so a poster export and an accessibility setting produce a still picture
/// rather than whatever frame happened to be on screen.
struct SBAnimatedCanvasHost<Content: View>: View {
    let animates: Bool
    /// Seconds between frames. Backdrops don't need 60fps; drifting skies read
    /// fine at 12–20 and cost far less on an Apple TV driving a 4K board.
    let period: Double
    @ViewBuilder let content: (Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStaticRender) private var isStaticRender

    private var isMoving: Bool { animates && !reduceMotion && !isStaticRender }

    var body: some View {
        if isMoving {
            TimelineView(.periodic(from: .now, by: period)) { context in
                content(context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            // A fixed instant, chosen so the still frame is a pleasant one
            // rather than everything sitting at phase zero.
            content(120)
        }
    }
}
