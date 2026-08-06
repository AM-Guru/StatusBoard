import SwiftUI

/// The Status Board look: near-black background, softly inset panels,
/// warm amber accent, LCD-flavored numerals.
public enum SBTheme {
    public static let background = Color(hex: 0x0E1013)
    public static let panelBackground = Color(hex: 0x191D23)
    public static let panelBorder = Color(hex: 0x2A2F37)
    public static let accent = Color(hex: 0xFFA028)
    public static let secondaryAccent = Color(hex: 0x35C4B5)
    public static let textPrimary = Color(hex: 0xF2F4F6)
    public static let textSecondary = Color(hex: 0x9AA3AD)
    public static let good = Color(hex: 0x4CD964)
    public static let warn = Color(hex: 0xFFCC00)
    public static let bad = Color(hex: 0xFF453A)

    public static let panelCornerRadius: CGFloat = 12

    public static func lcdFont(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    public static func titleFont(size: CGFloat = 13) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension ServiceStatus.State {
    public var color: Color {
        switch self {
        case .up: return SBTheme.good
        case .degraded: return SBTheme.warn
        case .down: return SBTheme.bad
        case .unknown: return SBTheme.textSecondary
        }
    }
}
