import SwiftUI

/// Per-panel accent color, injected by PanelView so every renderer (charts,
/// progress, clocks, big numbers) picks it up without plumbing parameters.
private struct PanelAccentKey: EnvironmentKey {
    static let defaultValue: Color = SBTheme.accent
}

extension EnvironmentValues {
    public var panelAccent: Color {
        get { self[PanelAccentKey.self] }
        set { self[PanelAccentKey.self] = newValue }
    }
}

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB".
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// "#RRGGBB" in sRGB, for persisting user-picked colors.
    public func hexString() -> String? {
        #if os(macOS)
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let red = converted.redComponent
        let green = converted.greenComponent
        let blue = converted.blueComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        func clamp(_ component: CGFloat) -> Int {
            Int((min(1, max(0, component)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }
}

extension PanelSettings {
    public var accentColor: Color? {
        accentColorHex.flatMap(Color.init(hexString:))
    }
}
