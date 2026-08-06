import Foundation
import CoreGraphics
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The screens a board can be laid out for. One board syncs everywhere, but a
/// 16:9 TV across the room and a phone in your hand want different arrangements,
/// so each device class can carry its own overrides.
public enum SBDeviceClass: String, Codable, CaseIterable, Identifiable, Sendable {
    case mac
    case pad
    case phone
    case tv
    case watch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .pad: return "iPad"
        case .phone: return "iPhone"
        case .tv: return "Apple TV"
        case .watch: return "Apple Watch"
        }
    }

    public var symbolName: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .pad: return "ipad.landscape"
        case .phone: return "iphone"
        case .tv: return "appletv"
        case .watch: return "applewatch"
        }
    }

    /// A representative screen size in points. The simulator lays a board out at
    /// exactly this size and then scales the whole thing down to fit, so panel
    /// text shrinks in proportion and you can see what will actually be legible.
    public var nominalPointSize: CGSize {
        switch self {
        case .mac: return CGSize(width: 1440, height: 900)
        case .pad: return CGSize(width: 1024, height: 768)
        case .phone: return CGSize(width: 393, height: 852)
        case .tv: return CGSize(width: 1920, height: 1080)
        case .watch: return CGSize(width: 184, height: 224)
        }
    }

    /// Width ÷ height of a representative screen.
    public var previewAspectRatio: Double {
        nominalPointSize.width / nominalPointSize.height
    }

    /// Margins a TV may crop (tvOS's own title-safe inset), drawn as a guide in
    /// the simulator. Zero on screens that show every pixel.
    public var overscanInset: CGSize {
        self == .tv ? CGSize(width: 60, height: 30) : .zero
    }

    /// A plain-language reminder of what that screen is like, shown in the
    /// simulator so the arrangement choices make sense.
    public var previewNote: String {
        switch self {
        case .mac: return "Resizable window, 16:10 shown"
        case .pad: return "4:3 landscape"
        case .phone: return "Tall and narrow — few panels read well"
        case .tv: return "16:9, viewed from across the room"
        case .watch: return "Tiny — one panel at a time"
        }
    }

    /// A grid that suits the shape of this screen, used when a device layout is
    /// first created from scratch.
    public var suggestedGrid: BoardGrid {
        switch self {
        case .mac: return BoardGrid(columns: 8, rows: 4)
        case .pad: return BoardGrid(columns: 6, rows: 4)
        case .phone: return BoardGrid(columns: 2, rows: 6)
        case .tv: return BoardGrid(columns: 8, rows: 4)
        case .watch: return BoardGrid(columns: 1, rows: 2)
        }
    }

    /// The class of the screen this code is running on.
    public static var current: SBDeviceClass {
        #if os(tvOS)
        return .tv
        #elseif os(watchOS)
        return .watch
        #elseif os(macOS)
        return .mac
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }
}

/// A per-device arrangement of an existing board. It never adds or removes
/// panels — it only moves, resizes, and hides the ones the board already has,
/// so the board stays a single synced object.
public struct BoardLayout: Codable, Hashable, Sendable {
    /// Grid for this device; `nil` inherits the board's own grid.
    public var grid: BoardGrid?
    /// Panel ID (as a UUID string) → the frame it takes on this device.
    public var frames: [String: GridRect]
    /// Panel IDs kept off this device entirely.
    public var hiddenPanelIDs: Set<String>

    public init(grid: BoardGrid? = nil,
                frames: [String: GridRect] = [:],
                hiddenPanelIDs: Set<String> = []) {
        self.grid = grid
        self.frames = frames
        self.hiddenPanelIDs = hiddenPanelIDs
    }

    /// True when this layout says nothing at all, so it can be dropped rather
    /// than synced as noise.
    public var isEmpty: Bool {
        grid == nil && frames.isEmpty && hiddenPanelIDs.isEmpty
    }
}

// MARK: - Resolution

extension Dashboard {
    /// The stored overrides for a device, if it has any.
    public func layout(for device: SBDeviceClass) -> BoardLayout? {
        deviceLayouts[device.rawValue]
    }

    public func hasCustomLayout(for device: SBDeviceClass) -> Bool {
        guard let layout = layout(for: device) else { return false }
        return !layout.isEmpty
    }

    /// The grid a device draws on: its own if customized, otherwise the board's.
    /// Always tall enough to contain every panel it shows, so a panel can never
    /// fall off the bottom of the screen.
    public func grid(for device: SBDeviceClass) -> BoardGrid {
        var resolved = layout(for: device)?.grid ?? grid
        let bottom = panels(for: device).map { $0.frame.y + $0.frame.height }.max() ?? 0
        let right = panels(for: device).map { $0.frame.x + $0.frame.width }.max() ?? 0
        resolved.rows = max(resolved.rows, bottom)
        resolved.columns = max(resolved.columns, right)
        return resolved
    }

    /// The panels a device shows, with this device's frames applied.
    public func panels(for device: SBDeviceClass) -> [Panel] {
        guard let layout = layout(for: device) else { return panels }
        return panels.compactMap { panel in
            let key = panel.id.uuidString
            guard !layout.hiddenPanelIDs.contains(key) else { return nil }
            guard let frame = layout.frames[key] else { return panel }
            var moved = panel
            moved.frame = frame
            return moved
        }
    }

    /// The frame one panel takes on a device.
    public func frame(for panel: Panel, device: SBDeviceClass) -> GridRect {
        layout(for: device)?.frames[panel.id.uuidString] ?? panel.frame
    }

    public func isHidden(_ panelID: Panel.ID, on device: SBDeviceClass) -> Bool {
        layout(for: device)?.hiddenPanelIDs.contains(panelID.uuidString) ?? false
    }

    // MARK: Mutation

    /// Starts a device layout off as a copy of what that device shows today, so
    /// customizing never begins from a blank screen.
    public mutating func beginCustomLayout(for device: SBDeviceClass) {
        guard !hasCustomLayout(for: device) else { return }
        var layout = BoardLayout(grid: grid)
        for panel in panels {
            layout.frames[panel.id.uuidString] = panel.frame
        }
        deviceLayouts[device.rawValue] = layout
    }

    public mutating func setFrame(_ frame: GridRect, for panelID: Panel.ID,
                                  on device: SBDeviceClass) {
        beginCustomLayout(for: device)
        deviceLayouts[device.rawValue]?.frames[panelID.uuidString] = frame
    }

    public mutating func setHidden(_ hidden: Bool, for panelID: Panel.ID,
                                   on device: SBDeviceClass) {
        beginCustomLayout(for: device)
        if hidden {
            deviceLayouts[device.rawValue]?.hiddenPanelIDs.insert(panelID.uuidString)
        } else {
            deviceLayouts[device.rawValue]?.hiddenPanelIDs.remove(panelID.uuidString)
        }
    }

    public mutating func setGrid(_ newGrid: BoardGrid, on device: SBDeviceClass) {
        beginCustomLayout(for: device)
        deviceLayouts[device.rawValue]?.grid = newGrid
    }

    /// Drops a device's overrides; it goes back to following the shared layout.
    public mutating func resetLayout(for device: SBDeviceClass) {
        deviceLayouts[device.rawValue] = nil
    }

    /// Copies one device's arrangement onto another.
    public mutating func copyLayout(from source: SBDeviceClass, to target: SBDeviceClass) {
        if let existing = deviceLayouts[source.rawValue] {
            deviceLayouts[target.rawValue] = existing
        } else {
            // The source follows the shared layout, so the target should too.
            resetLayout(for: target)
        }
    }

    /// Rearranges a device's panels into a tidy grid that fits its screen,
    /// keeping the current order and dropping nothing. Used by "Auto-Arrange".
    public mutating func autoArrange(for device: SBDeviceClass) {
        beginCustomLayout(for: device)
        let visible = panels.filter { !isHidden($0.id, on: device) }
        guard !visible.isEmpty else { return }
        let columns = max(1, device.suggestedGrid.columns)
        // Keep each panel's proportions where they fit, otherwise clamp to the
        // row width; pack left to right, wrapping when a row fills up.
        var x = 0
        var y = 0
        var rowHeight = 0
        for panel in visible {
            let width = min(max(1, frame(for: panel, device: device).width), columns)
            let height = max(1, frame(for: panel, device: device).height)
            if x + width > columns {
                x = 0
                y += max(1, rowHeight)
                rowHeight = 0
            }
            deviceLayouts[device.rawValue]?.frames[panel.id.uuidString] =
                GridRect(x: x, y: y, width: width, height: height)
            x += width
            rowHeight = max(rowHeight, height)
        }
        let rows = y + max(1, rowHeight)
        deviceLayouts[device.rawValue]?.grid = BoardGrid(columns: columns, rows: rows)
    }
}
