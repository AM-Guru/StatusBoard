import SwiftUI

/// Everything painted behind a panel's content, in one place.
///
/// Bottom to top: an optional system blur, the chosen fill (theme color,
/// gradient, image, or a masked slice of the board's backdrop), whatever the
/// panel's own data asked for (a weather sky, a status wash), and a scrim to
/// keep text readable over a busy picture.
struct PanelBackgroundView: View {
    let appearance: PanelAppearance
    let theme: SBThemeName
    let dynamic: SBDynamicAppearance
    let accent: Color

    @Environment(\.sbBoardBackdrop) private var backdrop

    private var palette: SBPalette { theme.palette }

    /// A theme can bring its own material — Glass is translucent by design —
    /// but an explicit choice on the panel wins.
    private var material: PanelMaterialStyle {
        appearance.material != .none ? appearance.material
            : (appearance.backgroundStyle == .theme ? palette.material : .none)
    }

    var body: some View {
        ZStack {
            materialLayer
            fillLayer
                .overlay { dynamicLayer }
                .blur(radius: appearance.backgroundBlur)
                .opacity(min(1, max(0, appearance.backgroundOpacity)))
            if appearance.scrim > 0 {
                (palette.isLight ? Color.white : Color.black)
                    .opacity(min(1, max(0, appearance.scrim)))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var materialLayer: some View {
        switch material {
        case .none: Color.clear
        case .ultraThin: Rectangle().fill(.ultraThinMaterial)
        case .thin: Rectangle().fill(.thinMaterial)
        case .regular: Rectangle().fill(.regularMaterial)
        case .thick: Rectangle().fill(.thickMaterial)
        }
    }

    @ViewBuilder
    private var fillLayer: some View {
        switch appearance.backgroundStyle {
        case .theme:
            SBGradientFill(colors: palette.background.map(Color.init(hex:)),
                           angle: appearance.gradientAngle)
                .opacity(palette.backgroundAlpha)
        case .solid:
            appearance.backgroundColorHex.flatMap(Color.init(hexString:))
                ?? Color(hex: palette.background.first ?? 0x191D23)
        case .gradient:
            SBGradientFill(colors: gradientColors, angle: appearance.gradientAngle)
        case .image:
            SBBackdropImageView(urlString: appearance.backgroundImageURL,
                                fill: appearance.imageFill)
        case .boardBackdrop:
            if let backdrop {
                SBMaskedBoardBackdrop(backdrop: backdrop)
            } else {
                // Off a board — in a widget, a watch list, the simulator's
                // chrome — there is nothing to mask, so fall back to the theme
                // rather than punching a hole in the panel.
                SBGradientFill(colors: palette.background.map(Color.init(hex:)),
                               angle: appearance.gradientAngle)
            }
        case .material:
            // The material below is the whole point; nothing else on top.
            Color.clear
        case .clear:
            Color.clear
        }
    }

    private var gradientColors: [Color] {
        let colors = appearance.gradientColorHexes.compactMap(Color.init(hexString:))
        if colors.count >= 2 { return colors }
        // A single color, or none: fade the panel color into the accent so the
        // gradient style always shows something deliberate.
        let base = appearance.backgroundColorHex.flatMap(Color.init(hexString:))
            ?? Color(hex: palette.background.first ?? 0x191D23)
        return colors.count == 1 ? [colors[0], base] : [base, accent.opacity(0.35)]
    }

    @ViewBuilder
    private var dynamicLayer: some View {
        let strength = min(1, max(0, appearance.dynamicIntensity))
        switch dynamic.backdrop {
        case .none:
            EmptyView()
        case .weather(let report):
            WeatherBackdropView(report: report, intensity: strength,
                                animates: appearance.animates)
                .overlay { legibilityScrim }
        case .wash(let color):
            SBWashBackdrop(color: color, intensity: strength)
        case .timeOfDay:
            SBTimeOfDayBackdrop(intensity: strength * 0.85, animates: appearance.animates)
                .overlay { legibilityScrim }
        }
    }

    /// A sky can be bright noon blue or black midnight, and the panel's text is
    /// one color either way. This keeps the corner the text sits in dark enough
    /// to read without hiding the weather behind it.
    private var legibilityScrim: some View {
        LinearGradient(colors: [.black.opacity(palette.isLight ? 0.05 : 0.42), .clear],
                       startPoint: .bottomLeading, endPoint: .topTrailing)
    }
}

extension PanelAppearance {
    /// The corner radius this panel actually draws with.
    func resolvedCornerRadius(theme: SBThemeName) -> CGFloat {
        CGFloat(cornerRadius ?? theme.palette.cornerRadius)
    }

    /// The border color, honoring the theme's own alpha for translucent looks.
    func resolvedBorderColor(theme: SBThemeName) -> Color {
        if let custom = borderColorHex.flatMap(Color.init(hexString:)) { return custom }
        let palette = theme.palette
        return Color(hex: palette.border).opacity(palette.borderAlpha)
    }

    func resolvedBorderWidth() -> CGFloat {
        CGFloat(borderWidth ?? 1)
    }
}
