import SwiftUI

/// An animated sky matching a weather report: the right cloud cover, the right
/// precipitation, and the sun or the moon depending on whether it's daylight
/// where the report came from.
///
/// Everything is drawn from the clock rather than from stored particle state,
/// so the scene is identical in the panel, in the device simulator, and in an
/// exported board image — and it costs nothing when it isn't on screen.
struct WeatherBackdropView: View {
    let report: WeatherReport
    var intensity: Double = 1
    var animates: Bool = true

    private var scene: WeatherScene { WeatherScene.forCode(report.code) }

    var body: some View {
        let palette = SkyPalette.of(scene: scene, isDaytime: report.isDaytime)
        ZStack {
            LinearGradient(colors: [palette.top, palette.bottom],
                           startPoint: .top, endPoint: .bottom)
            SBAnimatedCanvasHost(animates: animates, period: 1 / 20) { time in
                Canvas { context, size in
                    draw(scene: scene, palette: palette, time: time,
                         context: &context, size: size)
                }
            }
        }
        .opacity(min(1, max(0, intensity)))
        .drawingGroup(opaque: false)
    }

    // MARK: - Scene composition

    private func draw(scene: WeatherScene, palette: SkyPalette, time: Double,
                      context: inout GraphicsContext, size: CGSize) {
        switch scene {
        case .clear, .partlyCloudy:
            if report.isDaytime {
                drawSun(palette: palette, time: time, context: &context, size: size)
            } else {
                drawStars(time: time, context: &context, size: size)
                drawMoon(palette: palette, context: &context, size: size)
            }
        default:
            break
        }

        let cloudCount: Int
        switch scene {
        case .clear: cloudCount = 0
        case .partlyCloudy: cloudCount = 3
        case .drizzle: cloudCount = 4
        case .snow: cloudCount = 4
        case .rain, .thunder: cloudCount = 5
        case .overcast: cloudCount = 6
        case .fog: cloudCount = 2
        }
        drawClouds(count: cloudCount, palette: palette, time: time,
                   context: &context, size: size)

        switch scene {
        case .drizzle:
            drawRain(count: 44, speed: 190, length: 7, palette: palette,
                     time: time, context: &context, size: size)
        case .rain:
            drawRain(count: 90, speed: 340, length: 13, palette: palette,
                     time: time, context: &context, size: size)
        case .thunder:
            drawRain(count: 110, speed: 400, length: 15, palette: palette,
                     time: time, context: &context, size: size)
            drawLightning(time: time, context: &context, size: size)
        case .snow:
            drawSnow(count: 60, time: time, context: &context, size: size)
        case .fog:
            drawFog(palette: palette, time: time, context: &context, size: size)
        case .clear, .partlyCloudy, .overcast:
            break
        }
    }

    // MARK: - Elements

    private func drawSun(palette: SkyPalette, time: Double,
                         context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.82, y: size.height * 0.26)
        let radius = min(size.width, size.height) * 0.16
        // A slow breath, so a clear sky isn't completely static.
        let pulse = 1 + 0.06 * sin(time * 0.6)
        let glow = radius * 3.2 * pulse
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow,
                                   width: glow * 2, height: glow * 2)),
            with: .radialGradient(Gradient(colors: [palette.highlight.opacity(0.5), .clear]),
                                  center: center, startRadius: 0, endRadius: glow))
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .color(palette.highlight))
    }

    private func drawMoon(palette: SkyPalette, context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.82, y: size.height * 0.26)
        let radius = min(size.width, size.height) * 0.13
        let glow = radius * 2.6
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow,
                                   width: glow * 2, height: glow * 2)),
            with: .radialGradient(Gradient(colors: [palette.highlight.opacity(0.30), .clear]),
                                  center: center, startRadius: 0, endRadius: glow))
        // A crescent: the lit disc with a shadow disc offset across it.
        var moon = context
        moon.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .color(palette.highlight))
        moon.blendMode = .destinationOut
        moon.fill(
            Path(ellipseIn: CGRect(x: center.x - radius * 1.45, y: center.y - radius * 1.15,
                                   width: radius * 2, height: radius * 2)),
            with: .color(.white))
    }

    private func drawStars(time: Double, context: inout GraphicsContext, size: CGSize) {
        let count = max(18, min(140, Int(size.width * size.height / 1800)))
        for star in 0..<count {
            let x = sbNoise(star, 7) * size.width
            let y = sbNoise(star, 13) * size.height * 0.75
            let radius = 0.5 + sbNoise(star, 19) * 1.2
            let twinkle = 0.5 + 0.5 * sin(time * (0.7 + sbNoise(star, 23)) + sbNoise(star, 31) * 6.28)
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                with: .color(.white.opacity(0.28 + 0.55 * twinkle)))
        }
    }

    private func drawClouds(count: Int, palette: SkyPalette, time: Double,
                            context: inout GraphicsContext, size: CGSize) {
        guard count > 0 else { return }
        for cloud in 0..<count {
            let scale = 0.55 + sbNoise(cloud, 101) * 0.65
            let width = size.width * 0.42 * scale
            let height = width * 0.42
            let speed = 6 + sbNoise(cloud, 103) * 12
            let span = size.width + width * 2
            // Wraps around rather than restarting, so clouds never pop in.
            let raw = sbNoise(cloud, 107) * span + time * speed
            let x = raw.truncatingRemainder(dividingBy: span) - width
            let y = size.height * (0.06 + sbNoise(cloud, 109) * 0.5)
            let opacity = palette.cloudOpacity * (0.6 + sbNoise(cloud, 113) * 0.4)
            var puff = Path()
            puff.addEllipse(in: CGRect(x: x, y: y, width: width * 0.6, height: height))
            puff.addEllipse(in: CGRect(x: x + width * 0.26, y: y - height * 0.32,
                                       width: width * 0.58, height: height * 1.2))
            puff.addEllipse(in: CGRect(x: x + width * 0.48, y: y,
                                       width: width * 0.52, height: height * 0.92))
            context.fill(puff, with: .color(palette.cloud.opacity(opacity)))
        }
    }

    private func drawRain(count: Int, speed: Double, length: Double, palette: SkyPalette,
                          time: Double, context: inout GraphicsContext, size: CGSize) {
        var drops = Path()
        let fallHeight = size.height + length * 2
        // A slight slant reads as wind and stops the streaks looking like bars.
        let slant = length * 0.35
        for drop in 0..<count {
            let x = sbNoise(drop, 211) * (size.width + slant * 2) - slant
            let personalSpeed = speed * (0.75 + sbNoise(drop, 223) * 0.5)
            let raw = sbNoise(drop, 227) * fallHeight + time * personalSpeed
            let y = raw.truncatingRemainder(dividingBy: fallHeight) - length
            drops.move(to: CGPoint(x: x, y: y))
            drops.addLine(to: CGPoint(x: x - slant, y: y + length))
        }
        context.stroke(drops, with: .color(palette.precipitation.opacity(0.55)),
                       lineWidth: 1.2)
    }

    private func drawSnow(count: Int, time: Double,
                          context: inout GraphicsContext, size: CGSize) {
        let fallHeight = size.height + 24
        for flake in 0..<count {
            let personalSpeed = 22 + sbNoise(flake, 307) * 34
            let raw = sbNoise(flake, 311) * fallHeight + time * personalSpeed
            let y = raw.truncatingRemainder(dividingBy: fallHeight) - 12
            // Flakes sway as they fall instead of dropping like rain.
            let sway = sin(time * (0.5 + sbNoise(flake, 313)) + sbNoise(flake, 317) * 6.28) * 12
            let x = sbNoise(flake, 319) * size.width + sway
            let radius = 1.1 + sbNoise(flake, 331) * 2.0
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.55 + sbNoise(flake, 337) * 0.4)))
        }
    }

    private func drawFog(palette: SkyPalette, time: Double,
                         context: inout GraphicsContext, size: CGSize) {
        for band in 0..<5 {
            let height = size.height * 0.22
            let y = size.height * (0.1 + Double(band) * 0.18)
            let speed = 5 + Double(band) * 3
            let span = size.width * 2
            let raw = sbNoise(band, 401) * span + time * speed
            let x = raw.truncatingRemainder(dividingBy: span) - size.width
            let rect = CGRect(x: x, y: y, width: size.width * 1.4, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: height / 2),
                         with: .color(palette.cloud.opacity(0.16)))
        }
    }

    private func drawLightning(time: Double, context: inout GraphicsContext, size: CGSize) {
        // One candidate strike every four seconds; most are skipped, so the
        // flashes stay irregular without needing random state.
        let slot = Int(floor(time / 4))
        guard sbNoise(slot, 503) > 0.45 else { return }
        let start = Double(slot) * 4 + sbNoise(slot, 509) * 3
        let age = time - start
        guard age >= 0, age < 0.42 else { return }
        // Two quick pulses, like a real strike.
        let pulse = age < 0.09 ? 1.0 : (age < 0.18 ? 0.25 : (age < 0.27 ? 0.7 : max(0, 1 - age / 0.42)))
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.white.opacity(0.34 * pulse)))

        // A branching bolt down from the cloud layer.
        var bolt = Path()
        var point = CGPoint(x: size.width * (0.25 + sbNoise(slot, 521) * 0.5),
                            y: size.height * 0.12)
        bolt.move(to: point)
        for step in 1...5 {
            point = CGPoint(x: point.x + (sbNoise(slot &* 31 &+ step, 523) - 0.5) * size.width * 0.16,
                            y: point.y + size.height * 0.13)
            bolt.addLine(to: point)
        }
        context.stroke(bolt, with: .color(.white.opacity(0.85 * pulse)), lineWidth: 2)
    }
}

/// The colors one sky is made of.
struct SkyPalette: Equatable {
    var top: Color
    var bottom: Color
    var cloud: Color
    /// The sun or the moon.
    var highlight: Color
    var precipitation: Color
    var cloudOpacity: Double

    static func of(scene: WeatherScene, isDaytime: Bool) -> SkyPalette {
        switch (scene, isDaytime) {
        case (.clear, true):
            return SkyPalette(top: Color(hex: 0x2A83C9), bottom: Color(hex: 0xA8D8F0),
                              cloud: .white, highlight: Color(hex: 0xFFE9A8),
                              precipitation: .white, cloudOpacity: 0.7)
        case (.clear, false):
            return SkyPalette(top: Color(hex: 0x05070F), bottom: Color(hex: 0x141D3A),
                              cloud: Color(hex: 0x8A93AD), highlight: Color(hex: 0xE8ECF6),
                              precipitation: .white, cloudOpacity: 0.4)
        case (.partlyCloudy, true):
            return SkyPalette(top: Color(hex: 0x3E8CC4), bottom: Color(hex: 0xC2DCEC),
                              cloud: .white, highlight: Color(hex: 0xFFE9A8),
                              precipitation: .white, cloudOpacity: 0.78)
        case (.partlyCloudy, false):
            return SkyPalette(top: Color(hex: 0x0A1024), bottom: Color(hex: 0x212C46),
                              cloud: Color(hex: 0x8B95B0), highlight: Color(hex: 0xE8ECF6),
                              precipitation: .white, cloudOpacity: 0.45)
        case (.overcast, true):
            return SkyPalette(top: Color(hex: 0x6E7B88), bottom: Color(hex: 0xB0BAC4),
                              cloud: Color(hex: 0xE6EBF0), highlight: .white,
                              precipitation: .white, cloudOpacity: 0.8)
        case (.overcast, false):
            return SkyPalette(top: Color(hex: 0x14181F), bottom: Color(hex: 0x2E3540),
                              cloud: Color(hex: 0x76808D), highlight: .white,
                              precipitation: .white, cloudOpacity: 0.55)
        case (.fog, true):
            return SkyPalette(top: Color(hex: 0x8A929B), bottom: Color(hex: 0xCBD1D7),
                              cloud: .white, highlight: .white,
                              precipitation: .white, cloudOpacity: 0.5)
        case (.fog, false):
            return SkyPalette(top: Color(hex: 0x171B21), bottom: Color(hex: 0x333A43),
                              cloud: Color(hex: 0x9AA3AD), highlight: .white,
                              precipitation: .white, cloudOpacity: 0.4)
        case (.drizzle, true):
            return SkyPalette(top: Color(hex: 0x5D7386), bottom: Color(hex: 0x9BAEBD),
                              cloud: Color(hex: 0xDFE7ED), highlight: .white,
                              precipitation: Color(hex: 0xDCEBF7), cloudOpacity: 0.72)
        case (.drizzle, false):
            return SkyPalette(top: Color(hex: 0x111823), bottom: Color(hex: 0x27313F),
                              cloud: Color(hex: 0x707C8B), highlight: .white,
                              precipitation: Color(hex: 0xBFD4E6), cloudOpacity: 0.5)
        case (.rain, true):
            return SkyPalette(top: Color(hex: 0x46596B), bottom: Color(hex: 0x8797A6),
                              cloud: Color(hex: 0xD3DDE5), highlight: .white,
                              precipitation: Color(hex: 0xE2F0FA), cloudOpacity: 0.8)
        case (.rain, false):
            return SkyPalette(top: Color(hex: 0x0D1219), bottom: Color(hex: 0x212B38),
                              cloud: Color(hex: 0x66717E), highlight: .white,
                              precipitation: Color(hex: 0xB9D0E4), cloudOpacity: 0.55)
        case (.snow, true):
            return SkyPalette(top: Color(hex: 0x93A7B8), bottom: Color(hex: 0xE2ECF4),
                              cloud: .white, highlight: .white,
                              precipitation: .white, cloudOpacity: 0.75)
        case (.snow, false):
            return SkyPalette(top: Color(hex: 0x131A26), bottom: Color(hex: 0x303D52),
                              cloud: Color(hex: 0x8B97A8), highlight: .white,
                              precipitation: .white, cloudOpacity: 0.5)
        case (.thunder, true):
            return SkyPalette(top: Color(hex: 0x33384A), bottom: Color(hex: 0x6C7183),
                              cloud: Color(hex: 0xB8BECC), highlight: .white,
                              precipitation: Color(hex: 0xD9E6F2), cloudOpacity: 0.85)
        case (.thunder, false):
            return SkyPalette(top: Color(hex: 0x110F1C), bottom: Color(hex: 0x2C2740),
                              cloud: Color(hex: 0x5E5A75), highlight: .white,
                              precipitation: Color(hex: 0xC3D3E4), cloudOpacity: 0.65)
        }
    }
}
