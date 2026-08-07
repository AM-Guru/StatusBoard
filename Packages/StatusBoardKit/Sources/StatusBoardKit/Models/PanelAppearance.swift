import Foundation

/// Named looks a panel or a board can wear. `custom` means "the explicit
/// colors on this appearance win"; every other case supplies a palette.
///
/// Themes live in the model layer as raw hex so they stay Foundation-only and
/// unit-testable — `Theme.swift` turns them into SwiftUI colors.
public enum SBThemeName: String, Codable, CaseIterable, Sendable, Identifiable {
    case board
    case glass
    case carbon
    case slate
    case paper
    case terminal
    case blueprint
    case sunset
    case aurora
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .board: return "Status Board"
        case .glass: return "Glass"
        case .carbon: return "Carbon"
        case .slate: return "Slate"
        case .paper: return "Paper"
        case .terminal: return "Terminal"
        case .blueprint: return "Blueprint"
        case .sunset: return "Sunset"
        case .aurora: return "Aurora"
        case .custom: return "Custom"
        }
    }

    public var palette: SBPalette {
        switch self {
        case .board, .custom:
            return SBPalette(background: [0x191D23], boardBackground: [0x0E1013],
                             border: 0x2A2F37, textPrimary: 0xF2F4F6,
                             textSecondary: 0x9AA3AD, accent: 0xFFA028,
                             cornerRadius: 12, isLight: false)
        case .glass:
            return SBPalette(background: [0xFFFFFF], boardBackground: [0x101828, 0x1E2A44],
                             border: 0xFFFFFF, textPrimary: 0xFFFFFF,
                             textSecondary: 0xC7D0DC, accent: 0x7FD4FF,
                             cornerRadius: 18, isLight: false,
                             backgroundAlpha: 0.10, borderAlpha: 0.22,
                             material: .thin)
        case .carbon:
            return SBPalette(background: [0x141414, 0x1C1C1C], boardBackground: [0x000000],
                             border: 0x333333, textPrimary: 0xF5F5F5,
                             textSecondary: 0x8E8E93, accent: 0xFF9F0A,
                             cornerRadius: 10, isLight: false)
        case .slate:
            return SBPalette(background: [0x1E293B], boardBackground: [0x0B1220],
                             border: 0x334155, textPrimary: 0xE2E8F0,
                             textSecondary: 0x94A3B8, accent: 0x38BDF8,
                             cornerRadius: 14, isLight: false)
        case .paper:
            return SBPalette(background: [0xFFFFFF], boardBackground: [0xEDE9E1],
                             border: 0xD6D0C4, textPrimary: 0x1C1C1E,
                             textSecondary: 0x6B6B70, accent: 0xC2410C,
                             cornerRadius: 12, isLight: true)
        case .terminal:
            return SBPalette(background: [0x04120A], boardBackground: [0x010A05],
                             border: 0x1F6F3A, textPrimary: 0x7CFFA0,
                             textSecondary: 0x3E9E5F, accent: 0x39FF6A,
                             cornerRadius: 4, isLight: false)
        case .blueprint:
            return SBPalette(background: [0x0B2B57], boardBackground: [0x061B38],
                             border: 0x2F6DB5, textPrimary: 0xE8F1FF,
                             textSecondary: 0x9DBDE8, accent: 0x69B7FF,
                             cornerRadius: 6, isLight: false)
        case .sunset:
            return SBPalette(background: [0x3A1C4A, 0x7A2E4E], boardBackground: [0x1B0E2B, 0x4A1F3D],
                             border: 0x8E4A6B, textPrimary: 0xFFF1E6,
                             textSecondary: 0xE0B3C0, accent: 0xFF9E5E,
                             cornerRadius: 16, isLight: false)
        case .aurora:
            return SBPalette(background: [0x0C2230, 0x123A3A], boardBackground: [0x04121A, 0x0A2430],
                             border: 0x1E5A5A, textPrimary: 0xE6FFF7,
                             textSecondary: 0x9BD3C4, accent: 0x5EE7B0,
                             cornerRadius: 16, isLight: false)
        }
    }
}

/// A theme's resolved colors, as sRGB hex. Two or more `background` entries
/// mean the theme paints a gradient rather than a flat fill.
public struct SBPalette: Hashable, Sendable {
    public var background: [UInt32]
    public var boardBackground: [UInt32]
    public var border: UInt32
    public var textPrimary: UInt32
    public var textSecondary: UInt32
    public var accent: UInt32
    public var cornerRadius: Double
    public var isLight: Bool
    /// Alpha for the panel fill — themes like Glass are deliberately see-through.
    public var backgroundAlpha: Double
    public var borderAlpha: Double
    /// Blur material the theme layers behind its (translucent) fill.
    public var material: PanelMaterialStyle

    public init(background: [UInt32], boardBackground: [UInt32], border: UInt32,
                textPrimary: UInt32, textSecondary: UInt32, accent: UInt32,
                cornerRadius: Double, isLight: Bool,
                backgroundAlpha: Double = 1, borderAlpha: Double = 1,
                material: PanelMaterialStyle = .none) {
        self.background = background
        self.boardBackground = boardBackground
        self.border = border
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.isLight = isLight
        self.backgroundAlpha = backgroundAlpha
        self.borderAlpha = borderAlpha
        self.material = material
    }
}

/// How a panel fills itself behind its content.
public enum PanelBackgroundStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whatever the chosen theme paints.
    case theme
    case solid
    case gradient
    /// An image of its own, scaled inside the panel.
    case image
    /// The *board's* backdrop, aligned to the panel's place on the board — so
    /// one picture spans several panels and each shows its own slice.
    case boardBackdrop
    /// System blur of whatever is behind the panel.
    case material
    /// Nothing at all: the board shows straight through.
    case clear

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .theme: return "Theme"
        case .solid: return "Solid Color"
        case .gradient: return "Gradient"
        case .image: return "Image"
        case .boardBackdrop: return "Board Image (masked)"
        case .material: return "Blur"
        case .clear: return "Transparent"
        }
    }
}

/// Blur materials, mapped to SwiftUI `Material` in the UI layer.
public enum PanelMaterialStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case ultraThin
    case thin
    case regular
    case thick

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .ultraThin: return "Ultra Thin"
        case .thin: return "Thin"
        case .regular: return "Regular"
        case .thick: return "Thick"
        }
    }
}

/// How a background image is fitted into the space it is given.
public enum BackgroundImageFill: String, Codable, CaseIterable, Sendable, Identifiable {
    case fill
    case fit
    case tile

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// Procedural board wallpapers. Drawn from math rather than shipped as assets,
/// so they cost nothing to sync and stay sharp at any size — which also makes
/// them align exactly when several panels mask the same backdrop.
public enum SBWallpaper: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case aurora
    case dusk
    case grid
    case starfield
    case topography
    case halftone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .aurora: return "Aurora"
        case .dusk: return "Dusk"
        case .grid: return "Grid"
        case .starfield: return "Starfield"
        case .topography: return "Topography"
        case .halftone: return "Halftone"
        }
    }

    /// Wallpapers that move on their own when animation is allowed.
    public var isAnimated: Bool {
        switch self {
        case .aurora, .starfield: return true
        default: return false
        }
    }
}

/// Lets a panel restyle itself from its own data.
public enum DynamicAppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Never — the static appearance is used as configured.
    case off
    /// Choose by panel kind: weather panels get weather scenes, service checks
    /// get status coloring, numeric panels follow their alert thresholds.
    case automatic
    /// Animated sky matching the current conditions and time of day.
    case weather
    /// Green / amber / red from service state or assignment lateness.
    case status
    /// Green below `alertAbove`, red past it (and the mirror for `alertBelow`).
    case threshold
    /// Warms and cools through the day regardless of what the panel shows.
    case timeOfDay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatic"
        case .weather: return "Weather"
        case .status: return "Status"
        case .threshold: return "Thresholds"
        case .timeOfDay: return "Time of Day"
        }
    }
}

/// Everything about how one panel looks. Every field is optional-or-defaulted
/// and decoded with `decodeIfPresent`, so a board written by an older build —
/// or by another device that hasn't updated — still loads.
public struct PanelAppearance: Codable, Hashable, Sendable {
    public var theme: SBThemeName = .board
    public var backgroundStyle: PanelBackgroundStyle = .theme
    public var backgroundColorHex: String?
    public var gradientColorHexes: [String] = []
    /// Gradient direction in degrees, clockwise from "straight down".
    public var gradientAngle: Double = 135
    public var backgroundImageURL: String?
    public var imageFill: BackgroundImageFill = .fill
    /// Opacity of the background layer only — content stays legible.
    public var backgroundOpacity: Double = 1
    /// Gaussian blur applied to the background layer, in points.
    public var backgroundBlur: Double = 0
    /// A system blur layered *behind* the fill. Combine with a low
    /// `backgroundOpacity` for frosted panels over a board wallpaper.
    public var material: PanelMaterialStyle = .none
    public var contentOpacity: Double = 1
    /// Darkens (or with a light theme, lightens) the background behind text so
    /// a busy image doesn't swallow the content. 0…1.
    public var scrim: Double = 0
    public var cornerRadius: Double?
    public var borderWidth: Double?
    public var borderColorHex: String?
    public var textColorHex: String?
    public var secondaryTextColorHex: String?
    /// Outer glow, in points. Picks up the panel's accent (or dynamic) color.
    public var glowRadius: Double = 0
    public var dynamic: DynamicAppearanceMode = .automatic
    /// Motion in dynamic backdrops. Reduce Motion overrides this to false.
    public var animates: Bool = true
    /// How strongly the dynamic layer shows, 0…1.
    public var dynamicIntensity: Double = 1
    /// Hides the title bar even on kinds that normally show one — useful when
    /// a full-bleed backdrop should carry the panel on its own.
    public var hidesTitleBar: Bool = false

    public init() {}

    /// True when nothing has been customized, so callers can take the cheap
    /// path and skip the whole background pipeline.
    public var isDefault: Bool { self == PanelAppearance() }

    private enum CodingKeys: String, CodingKey {
        case theme, backgroundStyle, backgroundColorHex, gradientColorHexes, gradientAngle
        case backgroundImageURL, imageFill, backgroundOpacity, backgroundBlur, material
        case contentOpacity, scrim, cornerRadius, borderWidth, borderColorHex
        case textColorHex, secondaryTextColorHex, glowRadius
        case dynamic, animates, dynamicIntensity, hidesTitleBar
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(SBThemeName.self, forKey: .theme)) ?? .board
        backgroundStyle = (try? container.decodeIfPresent(PanelBackgroundStyle.self, forKey: .backgroundStyle)) ?? .theme
        backgroundColorHex = try container.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        gradientColorHexes = try container.decodeIfPresent([String].self, forKey: .gradientColorHexes) ?? []
        gradientAngle = try container.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? 135
        backgroundImageURL = try container.decodeIfPresent(String.self, forKey: .backgroundImageURL)
        imageFill = (try? container.decodeIfPresent(BackgroundImageFill.self, forKey: .imageFill)) ?? .fill
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        backgroundBlur = try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        material = (try? container.decodeIfPresent(PanelMaterialStyle.self, forKey: .material)) ?? .none
        contentOpacity = try container.decodeIfPresent(Double.self, forKey: .contentOpacity) ?? 1
        scrim = try container.decodeIfPresent(Double.self, forKey: .scrim) ?? 0
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius)
        borderWidth = try container.decodeIfPresent(Double.self, forKey: .borderWidth)
        borderColorHex = try container.decodeIfPresent(String.self, forKey: .borderColorHex)
        textColorHex = try container.decodeIfPresent(String.self, forKey: .textColorHex)
        secondaryTextColorHex = try container.decodeIfPresent(String.self, forKey: .secondaryTextColorHex)
        glowRadius = try container.decodeIfPresent(Double.self, forKey: .glowRadius) ?? 0
        dynamic = (try? container.decodeIfPresent(DynamicAppearanceMode.self, forKey: .dynamic)) ?? .automatic
        animates = try container.decodeIfPresent(Bool.self, forKey: .animates) ?? true
        dynamicIntensity = try container.decodeIfPresent(Double.self, forKey: .dynamicIntensity) ?? 1
        hidesTitleBar = try container.decodeIfPresent(Bool.self, forKey: .hidesTitleBar) ?? false
    }
}

/// How a whole board looks behind its panels. The board backdrop is also what
/// panels sample when they mask it through — see `PanelBackgroundStyle.boardBackdrop`.
public struct BoardAppearance: Codable, Hashable, Sendable {
    public var theme: SBThemeName = .board
    /// Applies `theme` to every panel that hasn't picked one of its own.
    public var appliesThemeToPanels: Bool = true
    public var backgroundColorHex: String?
    public var gradientColorHexes: [String] = []
    public var gradientAngle: Double = 135
    public var wallpaper: SBWallpaper = .none
    public var backgroundImageURL: String?
    public var imageFill: BackgroundImageFill = .fill
    public var backgroundOpacity: Double = 1
    public var backgroundBlur: Double = 0
    /// Darkens the backdrop so panels stay readable over a busy picture.
    public var scrim: Double = 0
    public var animates: Bool = true
    /// Space between panels, in points. Roomier boards suit wallpapers.
    public var panelSpacing: Double = 10

    public init() {}

    public var isDefault: Bool { self == BoardAppearance() }

    /// Whether anything at all is painted behind the panels beyond a flat color.
    public var hasBackdrop: Bool {
        wallpaper != .none || backgroundImageURL?.isEmpty == false
            || gradientColorHexes.count >= 2
    }

    private enum CodingKeys: String, CodingKey {
        case theme, appliesThemeToPanels, backgroundColorHex, gradientColorHexes, gradientAngle
        case wallpaper, backgroundImageURL, imageFill, backgroundOpacity, backgroundBlur
        case scrim, animates, panelSpacing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(SBThemeName.self, forKey: .theme)) ?? .board
        appliesThemeToPanels = try container.decodeIfPresent(Bool.self, forKey: .appliesThemeToPanels) ?? true
        backgroundColorHex = try container.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        gradientColorHexes = try container.decodeIfPresent([String].self, forKey: .gradientColorHexes) ?? []
        gradientAngle = try container.decodeIfPresent(Double.self, forKey: .gradientAngle) ?? 135
        wallpaper = (try? container.decodeIfPresent(SBWallpaper.self, forKey: .wallpaper)) ?? .none
        backgroundImageURL = try container.decodeIfPresent(String.self, forKey: .backgroundImageURL)
        imageFill = (try? container.decodeIfPresent(BackgroundImageFill.self, forKey: .imageFill)) ?? .fill
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        backgroundBlur = try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0
        scrim = try container.decodeIfPresent(Double.self, forKey: .scrim) ?? 0
        animates = try container.decodeIfPresent(Bool.self, forKey: .animates) ?? true
        panelSpacing = try container.decodeIfPresent(Double.self, forKey: .panelSpacing) ?? 10
    }
}
