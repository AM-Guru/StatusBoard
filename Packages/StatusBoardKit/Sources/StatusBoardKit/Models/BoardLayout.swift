import Foundation
import CoreGraphics
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Which way round a screen is being held. Only the iPhone and iPad turn, but
/// the two orientations are so different in shape that each gets its own
/// arrangement rather than one layout stretched to fit both.
public enum SBLayoutOrientation: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }

    public var symbolName: String {
        switch self {
        case .portrait: return "rectangle.portrait"
        case .landscape: return "rectangle"
        }
    }
}

/// The kinds of hardware a board can be arranged for, ignoring which way the
/// screen is turned. Rotation is a property of the arrangement, not of the
/// device, so the menus can offer "iPhone" once and then two orientations.
public enum SBDeviceFamily: String, CaseIterable, Identifiable, Sendable {
    case mac
    case pad
    case phone
    case tv
    case watch
    case glasses

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .pad: return "iPad"
        case .phone: return "iPhone"
        case .tv: return "Apple TV"
        case .watch: return "Apple Watch"
        case .glasses: return "Smart Glasses"
        }
    }

    /// The arrangements this family has — one per orientation for the screens
    /// that turn, otherwise just the one.
    public var layouts: [SBDeviceClass] {
        switch self {
        case .mac: return [.mac]
        case .pad: return [.pad, .padPortrait]
        case .phone: return [.phone, .phoneLandscape]
        case .tv: return [.tv]
        case .watch: return [.watch]
        case .glasses: return [.glasses]
        }
    }

    /// The arrangement used when a family is picked without saying which way
    /// the screen is turned.
    public var primaryLayout: SBDeviceClass { layouts[0] }

    /// Screens that only exist when something else is on the other end of a
    /// link. Status Board does not run on smart glasses — SybilSight draws the
    /// board on them — so that screen is only worth offering while a pair is
    /// actually linked to this Mac.
    public var requiresLink: Bool { self == .glasses }
}

/// The screens a board can be laid out for. One board syncs everywhere, but a
/// 16:9 TV across the room and a phone in your hand want different arrangements,
/// so each device class can carry its own overrides.
///
/// The iPhone and iPad appear twice — once per orientation — because a board
/// that reads well in a hand held upright is the wrong shape the moment the
/// screen turns. The raw values are the keys per-device layouts are stored
/// under, so the original five are left exactly as they were.
public enum SBDeviceClass: String, Codable, CaseIterable, Identifiable, Sendable {
    case mac
    case pad
    case padPortrait
    case phone
    case phoneLandscape
    case tv
    case watch
    /// Even Realities G2-class smart glasses, drawn by a linked SybilSight.
    /// Nothing in this app runs there; the arrangement is carried over the
    /// bridge and rendered on the lenses at the other end.
    case glasses

    public var id: String { rawValue }

    public var family: SBDeviceFamily {
        switch self {
        case .mac: return .mac
        case .pad, .padPortrait: return .pad
        case .phone, .phoneLandscape: return .phone
        case .tv: return .tv
        case .watch: return .watch
        case .glasses: return .glasses
        }
    }

    public var orientation: SBLayoutOrientation {
        switch self {
        case .padPortrait, .phone, .watch: return .portrait
        case .mac, .pad, .phoneLandscape, .tv, .glasses: return .landscape
        }
    }

    /// True for the screens that turn in the hand, and so have a second
    /// arrangement to keep in step.
    public var supportsRotation: Bool { family.layouts.count > 1 }

    /// The same device the other way up, or itself when it doesn't turn.
    public var rotated: SBDeviceClass {
        family.layouts.first { $0 != self } ?? self
    }

    public func inOrientation(_ orientation: SBLayoutOrientation) -> SBDeviceClass {
        family.layouts.first { $0.orientation == orientation } ?? self
    }

    /// The arrangement a rotated screen borrows from when it has none of its
    /// own: an iPhone on its side starts from the iPhone's own layout, not from
    /// the board's shared one.
    public var layoutFallback: SBDeviceClass? {
        switch self {
        case .padPortrait: return .pad
        case .phoneLandscape: return .phone
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .pad: return "iPad"
        case .padPortrait: return "iPad Portrait"
        case .phone: return "iPhone"
        case .phoneLandscape: return "iPhone Landscape"
        case .tv: return "Apple TV"
        case .watch: return "Apple Watch"
        case .glasses: return "Smart Glasses"
        }
    }

    public var symbolName: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .pad: return "ipad.landscape"
        case .padPortrait: return "ipad"
        case .phone: return "iphone"
        case .phoneLandscape: return "iphone.landscape"
        case .tv: return "appletv"
        case .watch: return "applewatch"
        case .glasses: return "eyeglasses"
        }
    }

    /// A screen drawn as light on dark with no colour at all. The glasses are a
    /// monochrome waveguide: everything reaches the eye as one green, so the
    /// preview is rendered through the same reduction rather than in full colour
    /// that nobody will ever see.
    public var isMonochrome: Bool { self == .glasses }

    /// A representative screen size in points. The simulator lays a board out at
    /// exactly this size and then scales the whole thing down to fit, so panel
    /// text shrinks in proportion and you can see what will actually be legible.
    public var nominalPointSize: CGSize {
        switch self {
        case .mac: return CGSize(width: 1440, height: 900)
        case .pad: return CGSize(width: 1024, height: 768)
        case .padPortrait: return CGSize(width: 768, height: 1024)
        case .phone: return CGSize(width: 393, height: 852)
        case .phoneLandscape: return CGSize(width: 852, height: 393)
        case .tv: return CGSize(width: 1920, height: 1080)
        case .watch: return CGSize(width: 184, height: 224)
        // The G2 canvas is 576×288 actual pixels, so one point here is one
        // pixel on the lenses. Nothing about this screen is approximate.
        case .glasses: return CGSize(width: 576, height: 288)
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

    /// The dashed boundary the simulator draws, and what to call it. A TV crops
    /// its edges to overscan; the glasses don't crop anything, but the corners of
    /// the waveguide fall outside a wearer's comfortable eyebox, so both screens
    /// want the same "keep it inside this" guide with different words.
    public struct ScreenGuide: Hashable, Sendable {
        public var inset: CGSize
        public var sectionTitle: String
        public var toggleTitle: String
        public var explanation: String
    }

    public var screenGuide: ScreenGuide? {
        switch self {
        case .tv:
            return ScreenGuide(
                inset: overscanInset,
                sectionTitle: "Overscan",
                toggleTitle: "Show TV-Safe Guide",
                explanation: "Some televisions crop the edges of the picture. Anything outside the dashed line may not be visible on your Apple TV.")
        case .glasses:
            return ScreenGuide(
                inset: CGSize(width: 24, height: 16),
                sectionTitle: "Eyebox",
                toggleTitle: "Show Lens-Safe Guide",
                explanation: "The glasses draw every pixel, but the far corners of the waveguide sit at the edge of where a wearer can comfortably look. Keep anything that has to be read inside the dashed line.")
        default:
            return nil
        }
    }

    /// A plain-language reminder of what that screen is like, shown in the
    /// simulator so the arrangement choices make sense.
    public var previewNote: String {
        switch self {
        case .mac: return "Resizable window, 16:10 shown"
        case .pad: return "4:3 landscape"
        case .padPortrait: return "3:4 upright — scrolls when the board runs long"
        case .phone: return "Tall and narrow — one column, scrolls"
        case .phoneLandscape: return "Short and wide — two columns, scrolls"
        case .tv: return "16:9, viewed from across the room"
        case .watch: return "Tiny — one panel at a time"
        case .glasses: return "576×288 monochrome, floating a metre in front of the wearer"
        }
    }

    /// A grid that suits the shape of this screen. It sets the column count for
    /// automatic arrangements and is the grid a device layout starts from.
    ///
    /// The row counts are how many rows fit on screen at a comfortable size, not
    /// a ceiling: an arrangement that needs more rows than these gets them, and
    /// the board scrolls.
    public var suggestedGrid: BoardGrid {
        switch self {
        case .mac: return BoardGrid(columns: 8, rows: 4)
        case .pad: return BoardGrid(columns: 6, rows: 4)
        case .padPortrait: return BoardGrid(columns: 4, rows: 6)
        case .phone: return BoardGrid(columns: 1, rows: 5)
        case .phoneLandscape: return BoardGrid(columns: 2, rows: 2)
        case .tv: return BoardGrid(columns: 8, rows: 4)
        case .watch: return BoardGrid(columns: 1, rows: 3)
        // Two by two is the most a 288-pixel-tall strip can say and still be
        // readable at a glance. It is a starting point, not a cap — the grid
        // stepper raises it, and the wearer is the one who decides whether four
        // panels or one is what they want in front of them.
        case .glasses: return BoardGrid(columns: 2, rows: 2)
        }
    }

    /// The shortest a single grid row may be drawn, in points. A board with more
    /// rows than fit at this height scrolls rather than squeezing every panel
    /// down to an unreadable sliver.
    public var minimumRowHeight: CGFloat {
        switch self {
        case .mac: return 140
        case .pad: return 150
        case .padPortrait: return 150
        case .phone: return 150
        case .phoneLandscape: return 130
        case .tv: return 0
        case .watch: return 96
        case .glasses: return 0
        }
    }

    /// Whether a board too tall for the screen may scroll. The Apple TV is a
    /// display, not something anyone scrolls from the sofa, and the glasses are
    /// a display nobody can scroll at all, so both always fit exactly.
    public var allowsScrolling: Bool { self != .tv && self != .glasses }

    /// Screens that arrange themselves from the board's shared layout instead of
    /// following it literally. A phone is nothing like an 8-column board, so it
    /// reflows into a single column until someone arranges it by hand.
    public var usesAutomaticLayout: Bool {
        switch self {
        case .phone, .phoneLandscape, .padPortrait, .watch, .glasses: return true
        case .mac, .pad, .tv: return false
        }
    }

    /// Panels that cannot say anything useful on this screen. On the glasses
    /// everything is one colour at 576×288: a photograph, a live web page and a
    /// twelve-column table all arrive as grey mush, and a map is worse than
    /// nothing. They are named rather than silently dropped, so the arrangement
    /// says why a panel isn't there.
    public var unsupportedPanelKinds: Set<PanelKind> {
        self == .glasses ? [.webClip, .image, .mcp] : []
    }

    public func supports(_ kind: PanelKind) -> Bool {
        !unsupportedPanelKinds.contains(kind)
    }

    /// The class of the screen this code is running on, in its usual
    /// orientation.
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

    /// The class for the room a board actually has. Measuring the board area
    /// rather than asking the device which way it is held is what makes this
    /// right in an iPad Split View or a half-height Slide Over, where the screen
    /// is landscape but the app's share of it is not.
    public static func current(forBoardSize size: CGSize) -> SBDeviceClass {
        let base = current
        guard base.supportsRotation, size.width > 0, size.height > 0 else { return base }
        return base.inOrientation(size.width >= size.height ? .landscape : .portrait)
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

// MARK: - Automatic arrangement

/// Reflows a board onto a screen it wasn't drawn for.
///
/// Two rules do all the work. A panel keeps the *share* of the width it had —
/// half a board stays half a board — so an arrangement tuned on a Mac reads the
/// same way on an iPad. And a panel whose content is a chart, a list or a table
/// is never squeezed below half the screen, because those are unreadable in a
/// narrow column no matter how much vertical room they get.
///
/// Free of any platform guard so it can be unit tested.
public enum SBAutoLayout {

    /// How many cells a panel takes on a target screen.
    public static func span(for kind: PanelKind, source: GridRect, sourceColumns: Int,
                            device: SBDeviceClass) -> (width: Int, height: Int) {
        let columns = max(1, device.suggestedGrid.columns)
        let needsRoom = WatchLayout.prefersFullWidth(kind)
        let sourceColumns = max(1, sourceColumns)

        let width: Int
        if columns == 1 {
            width = 1
        } else if sourceColumns <= 2 {
            // The source is itself a narrow column, so its widths say nothing
            // about proportion. Fall back to what the panel's content wants:
            // charts and lists take half the screen, readouts a quarter.
            width = needsRoom ? max(2, columns / 2) : max(1, columns / 4)
        } else {
            let share = Double(min(source.width, sourceColumns)) / Double(sourceColumns)
            let scaled = Int((share * Double(columns)).rounded())
            width = min(columns, max(needsRoom ? min(2, columns) : 1, scaled))
        }

        let height: Int
        if columns <= 2 {
            // Narrow screens have no width left to trade, so anything that
            // needs room takes it in rows instead.
            height = (needsRoom || source.height > 1) ? 2 : 1
        } else {
            height = min(3, max(1, source.height))
        }
        return (width, height)
    }

    /// Packs a board's panels into a tidy grid for one screen, keeping reading
    /// order and dropping nothing.
    ///
    /// `base` is the arrangement being reflowed *from*: the screen's own layout
    /// when it has one, the layout it inherits when it doesn't, otherwise the
    /// board's shared one. Its hidden panels stay hidden.
    public static func layout(for board: Dashboard, device: SBDeviceClass,
                              basedOn base: BoardLayout = BoardLayout()) -> BoardLayout {
        let columns = max(1, device.suggestedGrid.columns)
        let sourceColumns = base.grid?.columns ?? board.grid.columns
        func sourceFrame(_ panel: Panel) -> GridRect {
            base.frames[panel.id.uuidString] ?? panel.frame
        }

        // Reading order on the screen being reflowed from, so a board arranged
        // left to right on a Mac stacks top to bottom on a phone in the order it
        // was meant to be read.
        let ordered = board.panels.enumerated().sorted { lhs, rhs in
            let a = sourceFrame(lhs.element), b = sourceFrame(rhs.element)
            if a.y != b.y { return a.y < b.y }
            if a.x != b.x { return a.x < b.x }
            return lhs.offset < rhs.offset
        }.map(\.element)

        // A panel this screen cannot render is hidden by the arrangement rather
        // than left to draw nothing: on the glasses that is a web clip or a
        // photograph, which would otherwise take a quarter of the lenses to show
        // grey mush.
        var hiddenIDs = base.hiddenPanelIDs
        for panel in ordered where !device.supports(panel.kind) {
            hiddenIDs.insert(panel.id.uuidString)
        }
        let visible = ordered.filter { !hiddenIDs.contains($0.id.uuidString) }
        let hidden = ordered.filter { hiddenIDs.contains($0.id.uuidString) }

        var frames: [String: GridRect] = [:]
        // How far down each column is already filled. Each panel drops into the
        // highest place it fits, which closes the gaps a plain row-by-row pack
        // leaves under short panels — a tall chart beside a one-row readout
        // would otherwise waste the space below the readout entirely.
        var filled = [Int](repeating: 0, count: columns)
        func place(_ panel: Panel) {
            let span = span(for: panel.kind, source: sourceFrame(panel),
                            sourceColumns: sourceColumns, device: device)
            let width = min(max(1, span.width), columns)
            var bestX = 0
            var bestY = Int.max
            for x in 0...(columns - width) {
                let y = filled[x..<(x + width)].max() ?? 0
                if y < bestY {
                    bestY = y
                    bestX = x
                }
            }
            frames[panel.id.uuidString] = GridRect(x: bestX, y: bestY,
                                                   width: width, height: span.height)
            for column in bestX..<(bestX + width) {
                filled[column] = bestY + span.height
            }
        }

        visible.forEach(place)
        // The rows the screen actually shows stop with the last visible panel.
        let rows = visible.isEmpty
            ? max(1, device.suggestedGrid.rows)
            : max(1, filled.max() ?? 1)
        // Hidden panels are still given somewhere to land, below the fold, so
        // that showing one later puts it at the end of the board rather than
        // wherever it happened to sit on a screen eight columns wide.
        if !hidden.isEmpty {
            filled = [Int](repeating: rows, count: columns)
            hidden.forEach(place)
        }
        return BoardLayout(grid: BoardGrid(columns: columns, rows: rows),
                           frames: frames,
                           hiddenPanelIDs: hiddenIDs)
    }
}

// MARK: - Canvas

/// How tall a board is drawn on one screen, and whether that screen has to
/// scroll to see all of it.
///
/// Row height comes from the grid the board is arranged on, so the row count
/// stays the size control the layout editor promises it is — fewer rows, bigger
/// panels. The *canvas* stops at the last row anything occupies. A grid can
/// declare more rows than its panels reach: hiding or deleting the bottom panel
/// leaves its rows behind, the row stepper adds rows nobody has filled yet, and
/// a screen following a taller screen's arrangement inherits its row count. Draw
/// those empty rows and the board scrolls a long way past the end of its own
/// content, with nothing down there to look at.
///
/// Free of any platform guard so it can be unit tested.
public struct SBBoardCanvas: Equatable, Sendable {
    /// The height of one grid row, in points.
    public var rowHeight: CGFloat
    /// The height the board's content actually needs, in points.
    public var contentHeight: CGFloat
    /// Whether the content is taller than the room this screen gives it.
    public var scrolls: Bool
    /// The height to draw the board at: its content when that scrolls, the
    /// whole screen when it doesn't — so a backdrop still runs edge to edge.
    public var height: CGFloat { scrolls ? contentHeight : screenHeight }

    private var screenHeight: CGFloat

    /// - Parameters:
    ///   - screenHeight: the room the board has, inside its own padding.
    ///   - isEditing: while arranging, the canvas keeps every declared row —
    ///     the empty ones are where a panel is dragged to.
    public init(screenHeight: CGFloat, spacing: CGFloat, grid: BoardGrid,
                panels: [Panel], device: SBDeviceClass, isEditing: Bool) {
        self.screenHeight = screenHeight
        let rows = CGFloat(max(1, grid.rows))
        let fitted = (screenHeight - spacing) / rows
        // A row is never drawn shorter than the screen can read. When the board
        // has more rows than that allows, it grows past the bottom of the screen
        // and scrolls instead of squeezing every panel into an unreadable sliver.
        rowHeight = device.allowsScrolling ? max(fitted, device.minimumRowHeight) : fitted
        let filled = panels.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let drawn = isEditing ? max(1, grid.rows) : max(1, min(grid.rows, filled))
        contentHeight = rowHeight * CGFloat(drawn) + spacing
        // An empty board has nothing to scroll to; its message belongs centred
        // on the screen, not on a taller canvas behind it.
        scrolls = !panels.isEmpty && contentHeight > screenHeight + 0.5
    }
}

// MARK: - Resolution

extension Dashboard {
    /// The overrides stored for a device — what someone arranged by hand, and
    /// nothing else.
    public func layout(for device: SBDeviceClass) -> BoardLayout? {
        deviceLayouts[device.rawValue]
    }

    public func hasCustomLayout(for device: SBDeviceClass) -> Bool {
        guard let layout = layout(for: device) else { return false }
        return !layout.isEmpty
    }

    /// True when a screen is arranging itself rather than following a stored
    /// layout — the state a phone or a watch is in until someone drags a panel.
    public func usesAutomaticLayout(for device: SBDeviceClass) -> Bool {
        device.usesAutomaticLayout && !hasCustomLayout(for: device)
    }

    /// The arrangement a screen actually draws, in order of preference: its own
    /// stored layout; the layout it inherits when it is a rotation of another
    /// screen; an automatic arrangement for the screens that reflow; and
    /// finally an empty layout, meaning "follow the board".
    public func resolvedLayout(for device: SBDeviceClass) -> BoardLayout {
        if let stored = layout(for: device), !stored.isEmpty {
            return stored
        }
        var inherited = BoardLayout()
        if let fallback = device.layoutFallback {
            let candidate = resolvedLayout(for: fallback)
            if !candidate.isEmpty { inherited = candidate }
        }
        guard device.usesAutomaticLayout else { return inherited }
        return SBAutoLayout.layout(for: self, device: device, basedOn: inherited)
    }

    /// The grid a device draws on: its own if it has one, otherwise the board's.
    /// Always big enough to contain every panel it shows, so a panel can never
    /// fall off the edge of the screen.
    public func grid(for device: SBDeviceClass) -> BoardGrid {
        let layout = resolvedLayout(for: device)
        var resolved = layout.grid ?? grid
        let shown = panels(for: device, layout: layout)
        resolved.rows = max(resolved.rows, shown.map { $0.frame.y + $0.frame.height }.max() ?? 0)
        resolved.columns = max(resolved.columns, shown.map { $0.frame.x + $0.frame.width }.max() ?? 0)
        return resolved
    }

    /// The panels a device shows, with this device's frames applied.
    public func panels(for device: SBDeviceClass) -> [Panel] {
        panels(for: device, layout: resolvedLayout(for: device))
    }

    private func panels(for device: SBDeviceClass, layout: BoardLayout) -> [Panel] {
        guard !layout.isEmpty else { return panels }
        let frames = placedFrames(layout)
        return panels.compactMap { panel in
            let key = panel.id.uuidString
            guard !layout.hiddenPanelIDs.contains(key) else { return nil }
            guard let frame = frames[key] else { return panel }
            var moved = panel
            moved.frame = frame
            return moved
        }
    }

    /// Every panel's frame on one screen, including panels added to the board
    /// since that screen was arranged.
    ///
    /// A newcomer is parked in a row of its own at the end rather than keeping
    /// the frame it has on the board — on a phone showing a single column, a
    /// panel four columns wide would otherwise stretch the grid straight back
    /// out to the width of the board and shrink everything already on it.
    private func placedFrames(_ layout: BoardLayout) -> [String: GridRect] {
        guard !layout.isEmpty else { return [:] }
        var frames = layout.frames
        guard frames.count < panels.count else { return frames }
        let columns = max(1, layout.grid?.columns ?? grid.columns)
        var nextRow = layout.grid?.rows ?? 0
        for (key, frame) in frames where !layout.hiddenPanelIDs.contains(key) {
            nextRow = max(nextRow, frame.y + frame.height)
        }
        for panel in panels where frames[panel.id.uuidString] == nil {
            let height = max(1, panel.frame.height)
            frames[panel.id.uuidString] = GridRect(x: 0, y: nextRow,
                                                   width: min(panel.frame.width, columns),
                                                   height: height)
            nextRow += height
        }
        return frames
    }

    /// The panels a device shows, top to bottom and left to right. The watch
    /// stacks panels in this order rather than positioning them.
    public func panelsInReadingOrder(for device: SBDeviceClass) -> [Panel] {
        panels(for: device).enumerated().sorted { lhs, rhs in
            if lhs.element.frame.y != rhs.element.frame.y {
                return lhs.element.frame.y < rhs.element.frame.y
            }
            if lhs.element.frame.x != rhs.element.frame.x {
                return lhs.element.frame.x < rhs.element.frame.x
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The frame one panel takes on a device.
    public func frame(for panel: Panel, device: SBDeviceClass) -> GridRect {
        placedFrames(resolvedLayout(for: device))[panel.id.uuidString] ?? panel.frame
    }

    public func isHidden(_ panelID: Panel.ID, on device: SBDeviceClass) -> Bool {
        resolvedLayout(for: device).hiddenPanelIDs.contains(panelID.uuidString)
    }

    // MARK: Mutation

    /// Starts a device layout off as a copy of what that device shows today, so
    /// customizing never begins from a blank screen — and, on a screen that
    /// arranges itself, so the first drag freezes the arrangement it was already
    /// showing rather than throwing it away.
    public mutating func beginCustomLayout(for device: SBDeviceClass) {
        guard !hasCustomLayout(for: device) else { return }
        var layout = resolvedLayout(for: device)
        if layout.isEmpty {
            // This screen was following the board, so start from what the board
            // shows: same grid, same frames.
            layout.grid = grid
            for panel in panels {
                layout.frames[panel.id.uuidString] = panel.frame
            }
        } else {
            // It was arranging itself, or inheriting an arrangement. Freeze
            // exactly what it was already showing.
            layout.frames = placedFrames(layout)
            if layout.grid == nil { layout.grid = grid }
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

    /// Drops a device's overrides; it goes back to arranging itself, or to
    /// following the shared layout.
    public mutating func resetLayout(for device: SBDeviceClass) {
        deviceLayouts[device.rawValue] = nil
    }

    /// Copies one device's arrangement onto another.
    public mutating func copyLayout(from source: SBDeviceClass, to target: SBDeviceClass) {
        let resolved = resolvedLayout(for: source)
        if resolved.isEmpty {
            // The source follows the shared layout, so the target should too.
            resetLayout(for: target)
        } else {
            deviceLayouts[target.rawValue] = resolved
        }
    }

    /// Rearranges a device's panels into a tidy grid that suits its screen,
    /// keeping reading order and dropping nothing. Used by "Auto-Arrange" and by
    /// every screen that arranges itself.
    public mutating func autoArrange(for device: SBDeviceClass) {
        var base = layout(for: device) ?? BoardLayout()
        if base.isEmpty, let fallback = device.layoutFallback {
            base = resolvedLayout(for: fallback)
        }
        deviceLayouts[device.rawValue] = SBAutoLayout.layout(for: self, device: device,
                                                             basedOn: base)
    }
}
