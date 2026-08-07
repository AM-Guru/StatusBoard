import SwiftUI

/// The colors a panel's contents draw with, after the board theme and the
/// panel's own overrides have been resolved.
///
/// Renderers read this instead of reaching for `SBTheme` directly, which is
/// what lets a light theme like Paper — or a per-panel text color — reach the
/// charts, LCD numerals and lists without plumbing parameters through each one.
public struct SBPanelStyle: Equatable, Sendable {
    public var accent: Color
    public var textPrimary: Color
    public var textSecondary: Color
    /// Hairlines, zebra stripes and dividers inside a panel.
    public var separator: Color
    /// Legible against `accent` — for text and glyphs sitting on an accent chip.
    public var onAccent: Color
    public var good: Color
    public var warn: Color
    public var bad: Color
    public var cornerRadius: CGFloat
    public var isLight: Bool

    public init(accent: Color, textPrimary: Color, textSecondary: Color,
                separator: Color, onAccent: Color, good: Color, warn: Color,
                bad: Color, cornerRadius: CGFloat, isLight: Bool) {
        self.accent = accent
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.separator = separator
        self.onAccent = onAccent
        self.good = good
        self.warn = warn
        self.bad = bad
        self.cornerRadius = cornerRadius
        self.isLight = isLight
    }

    /// The classic Status Board look, and the value every view falls back to.
    public static let board = SBPanelStyle(palette: SBThemeName.board.palette)

    public init(palette: SBPalette, accentOverride: Color? = nil,
                textOverride: Color? = nil, secondaryTextOverride: Color? = nil,
                cornerRadiusOverride: CGFloat? = nil) {
        self.accent = accentOverride ?? Color(hex: palette.accent)
        self.textPrimary = textOverride ?? Color(hex: palette.textPrimary)
        self.textSecondary = secondaryTextOverride ?? Color(hex: palette.textSecondary)
        self.separator = Color(hex: palette.border)
        self.onAccent = palette.isLight ? Color.white : Color(hex: palette.boardBackground.first ?? 0x0E1013)
        // The stock semantic colors are tuned for a near-black panel; on a
        // light theme the yellow in particular disappears, so darken them.
        self.good = palette.isLight ? Color(hex: 0x1F8B3A) : SBTheme.good
        self.warn = palette.isLight ? Color(hex: 0xB07800) : SBTheme.warn
        self.bad = palette.isLight ? Color(hex: 0xC02A20) : SBTheme.bad
        self.cornerRadius = cornerRadiusOverride ?? palette.cornerRadius
        self.isLight = palette.isLight
    }
}

private struct SBPanelStyleKey: EnvironmentKey {
    static let defaultValue = SBPanelStyle.board
}

extension EnvironmentValues {
    /// Colors for the panel currently being drawn.
    public var sbStyle: SBPanelStyle {
        get { self[SBPanelStyleKey.self] }
        set { self[SBPanelStyleKey.self] = newValue }
    }
}

extension SBPanelStyle {
    /// Resolves the style for one panel: the board's theme unless the panel
    /// picks its own, then the panel's explicit color overrides on top.
    public static func resolve(panel: Panel, board: BoardAppearance,
                               dynamicAccent: Color? = nil) -> SBPanelStyle {
        let appearance = panel.settings.appearance
        // A panel left on the default theme follows the board, unless the
        // board has been told to keep its theme to itself.
        let themeName: SBThemeName = {
            if appearance.theme != .board { return appearance.theme }
            return board.appliesThemeToPanels ? board.theme : .board
        }()
        return SBPanelStyle(
            palette: themeName.palette,
            accentOverride: dynamicAccent ?? panel.settings.accentColor,
            textOverride: appearance.textColorHex.flatMap(Color.init(hexString:)),
            secondaryTextOverride: appearance.secondaryTextColorHex.flatMap(Color.init(hexString:)),
            cornerRadiusOverride: appearance.cornerRadius.map { CGFloat($0) })
    }

    /// The theme a panel resolves to, used by the background painter.
    public static func themeName(panel: Panel, board: BoardAppearance) -> SBThemeName {
        let appearance = panel.settings.appearance
        if appearance.theme != .board { return appearance.theme }
        return board.appliesThemeToPanels ? board.theme : .board
    }
}
