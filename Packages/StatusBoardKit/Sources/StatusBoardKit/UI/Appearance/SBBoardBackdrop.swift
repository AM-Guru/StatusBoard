import SwiftUI

/// What a panel needs to draw the board's backdrop in alignment with its
/// neighbours: the picture, how big the board is, and where this panel sits
/// on it.
///
/// A panel set to `PanelBackgroundStyle.boardBackdrop` draws the *whole* board
/// backdrop at board size and slides it up and left by its own origin, then
/// lets its rounded rectangle clip the result. Do that in every panel and one
/// picture reads continuously across all of them, with the gaps between panels
/// cutting into it.
public struct SBBoardBackdrop: Equatable {
    public var appearance: BoardAppearance
    public var boardSize: CGSize
    public var panelOrigin: CGPoint

    public init(appearance: BoardAppearance, boardSize: CGSize, panelOrigin: CGPoint) {
        self.appearance = appearance
        self.boardSize = boardSize
        self.panelOrigin = panelOrigin
    }
}

private struct SBBoardBackdropKey: EnvironmentKey {
    static let defaultValue: SBBoardBackdrop? = nil
}

extension EnvironmentValues {
    public var sbBoardBackdrop: SBBoardBackdrop? {
        get { self[SBBoardBackdropKey.self] }
        set { self[SBBoardBackdropKey.self] = newValue }
    }
}

/// The board's own background: base color, gradient, wallpaper, image, scrim.
struct SBBoardBackdropView: View {
    let appearance: BoardAppearance
    /// The board's full size, so wallpapers scale to the board rather than to
    /// whatever view happens to be hosting them.
    let size: CGSize

    private var palette: SBPalette { appearance.theme.palette }

    private var baseColors: [Color] {
        if appearance.gradientColorHexes.count >= 2 {
            return appearance.gradientColorHexes.compactMap(Color.init(hexString:))
        }
        if let solid = appearance.backgroundColorHex.flatMap(Color.init(hexString:)) {
            return [solid]
        }
        return palette.boardBackground.map(Color.init(hex:))
    }

    var body: some View {
        ZStack {
            SBGradientFill(colors: baseColors, angle: appearance.gradientAngle)
            // Named themes now carry their own surface treatment. A manually
            // selected wallpaper is additive and remains fully user-controlled.
            SBThemeTextureView(texture: palette.texture,
                               accent: Color(hex: palette.accent),
                               isLight: palette.isLight, intensity: 0.72)
            if appearance.wallpaper != .none {
                SBWallpaperView(wallpaper: appearance.wallpaper, size: size,
                                tint: Color(hex: palette.textPrimary),
                                animates: appearance.animates)
            }
            if let url = appearance.backgroundImageURL, !url.isEmpty {
                SBBackdropImageView(urlString: url, fill: appearance.imageFill)
            }
            if appearance.scrim > 0 {
                (palette.isLight ? Color.white : Color.black)
                    .opacity(min(1, max(0, appearance.scrim)))
            }
        }
        .frame(width: size.width, height: size.height)
        .blur(radius: appearance.backgroundBlur)
        .opacity(min(1, max(0, appearance.backgroundOpacity)))
        .clipped()
    }
}

/// A panel-sized window onto the board backdrop, aligned to the panel's place
/// on the board.
struct SBMaskedBoardBackdrop: View {
    let backdrop: SBBoardBackdrop

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            SBBoardBackdropView(appearance: backdrop.appearance, size: backdrop.boardSize)
                .frame(width: backdrop.boardSize.width, height: backdrop.boardSize.height,
                       alignment: .topLeading)
                .offset(x: -backdrop.panelOrigin.x, y: -backdrop.panelOrigin.y)
                .allowsHitTesting(false)
        }
        .clipped()
    }
}

/// One or more colors painted as a fill: a flat color for one, an angled
/// linear gradient for several.
struct SBGradientFill: View {
    let colors: [Color]
    /// Degrees clockwise from "top to bottom".
    var angle: Double = 135

    var body: some View {
        if colors.isEmpty {
            Color.clear
        } else if colors.count == 1 {
            colors[0]
        } else {
            LinearGradient(gradient: Gradient(colors: colors),
                           startPoint: Self.unitPoint(for: angle + 180),
                           endPoint: Self.unitPoint(for: angle))
        }
    }

    /// Maps an angle onto the unit square SwiftUI wants. 0° points down, and
    /// the values are clamped into 0…1 so the gradient always spans the view.
    static func unitPoint(for degrees: Double) -> UnitPoint {
        let radians = degrees * .pi / 180
        return UnitPoint(x: 0.5 + sin(radians) * 0.5, y: 0.5 + cos(radians) * 0.5)
    }
}
