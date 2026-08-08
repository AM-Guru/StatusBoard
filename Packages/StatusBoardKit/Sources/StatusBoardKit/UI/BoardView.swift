import SwiftUI

/// Renders one dashboard as a grid of panels. On iOS/macOS an edit mode
/// enables drag-to-move, drag-to-resize, configure, and delete; tvOS is
/// display-only with focus effects.
public struct BoardView: View {
    let model: AppModel
    let dashboardID: Dashboard.ID
    /// Which screen's arrangement to draw. `nil` means "this device", the
    /// normal case; the device simulator passes another screen's class to
    /// preview and edit its layout from here.
    let layoutTarget: SBDeviceClass?
    /// True inside the simulator, where the board is a picture of another
    /// screen rather than the live one — so panel context menus and the
    /// triple-tap reload stay out of the way.
    let isPreview: Bool
    /// Overrides the app-wide edit mode, so the simulator can be editable
    /// without putting the window behind it into edit mode too.
    let editingOverride: Bool?

    @State private var draggingPanelID: Panel.ID?
    @State private var resizingPanelID: Panel.ID?
    /// Where the panel under the gesture will land, in whole grid cells.
    @State private var gestureFrame: GridRect?

    /// Multiplier keeping the editing chrome a usable size when the board it
    /// sits on has been scaled down — see `sbEditorControlScale`.
    @Environment(\.sbEditorControlScale) private var controlScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Gaps between panels. The board's appearance can open this up, which
    /// suits a wallpaper showing through — so it is read per board rather than
    /// being the fixed 10pt it used to be.
    private var spacing: CGFloat {
        CGFloat(model.store.dashboard(id: dashboardID)?.appearance.panelSpacing ?? 10)
    }

    /// Drags are measured against the board, which never moves. A panel's own
    /// coordinate space travels with it, so once the panel starts snapping in
    /// whole cells the jump lands back in the next event's translation and the
    /// panel oscillates between two positions on alternating frames.
    private static let boardSpace = "sb.board"

    public init(model: AppModel, dashboardID: Dashboard.ID,
                layoutTarget: SBDeviceClass? = nil, isPreview: Bool = false,
                editingOverride: Bool? = nil) {
        self.model = model
        self.dashboardID = dashboardID
        self.layoutTarget = layoutTarget
        self.isPreview = isPreview
        self.editingOverride = editingOverride
    }

    private var isEditing: Bool { editingOverride ?? model.isEditing }

    public var body: some View {
        let boardAppearance = model.store.dashboard(id: dashboardID)?.appearance ?? BoardAppearance()
        GeometryReader { proxy in
            if let board = model.store.dashboard(id: dashboardID) {
                // The screen being laid out: the simulator's target, or the
                // shape this board actually has right now. Measuring the board
                // area is what makes rotation work without asking the system
                // which way the device is held — turning an iPhone changes the
                // area, which re-runs this and swaps in the other arrangement.
                let device = layoutTarget ?? SBDeviceClass.current(forBoardSize: proxy.size)
                let grid = board.grid(for: device)
                let panels = board.panels(for: device)
                let cellWidth = (proxy.size.width - spacing) / CGFloat(max(1, grid.columns))
                // Row height, and how far down the board is worth drawing: the
                // canvas ends with the last row a panel occupies rather than
                // with the grid, so nothing scrolls into empty rows.
                let canvas = SBBoardCanvas(screenHeight: proxy.size.height, spacing: spacing,
                                           grid: grid, panels: panels, device: device,
                                           isEditing: isEditing,
                                           contentScale: CGFloat(board.appearance.contentScale)
                                               * dynamicTypeContentScale)
                let cellHeight = canvas.rowHeight
                let scrolls = canvas.scrolls
                let height = canvas.height
                let content = ZStack(alignment: .topLeading) {
                    if isEditing {
                        gridGuides(grid: grid, cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    ForEach(panels) { panel in
                        panelCell(panel, board: board, device: device, grid: grid,
                                  cellWidth: cellWidth, cellHeight: cellHeight,
                                  boardSize: CGSize(width: proxy.size.width, height: height))
                    }
                    if panels.isEmpty {
                        emptyState(device: device, boardHasPanels: !board.panels.isEmpty)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: height, alignment: .topLeading)
                .coordinateSpace(.named(Self.boardSpace))
                // A tick every time a drag crosses into the next cell, so a
                // finger covering the panel it is moving can still feel where
                // the panel has got to.
                .sensoryFeedback(.selection, trigger: gestureFrame)
                #if !os(tvOS) && !os(watchOS)
                // Arrow keys nudge the selected panel a cell at a time, Option
                // resizes instead of moving. Focusable only while editing so the
                // board is not a tab stop on a screen nobody can change.
                .focusable(isEditing)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    nudge(press.key, resizing: press.modifiers.contains(.option),
                          panels: panels, device: device, grid: grid)
                }
                #endif

                if scrolls {
                    ScrollView(.vertical) { content }
                        .scrollIndicators(.automatic)
                } else {
                    content
                }
            }
        }
        .padding(spacing)
        .background {
            // Behind the padding too, so a wallpaper runs to the edges of the
            // screen rather than stopping at the panel margin.
            GeometryReader { proxy in
                SBBoardBackdropView(appearance: boardAppearance, size: proxy.size)
            }
            .ignoresSafeArea()
        }
    }

    /// Panel typography is geometry-driven so it can remain balanced inside a
    /// dashboard tile. Accessibility Dynamic Type therefore enlarges the grid
    /// rows as well as ordinary SwiftUI labels, preserving that relationship
    /// and allowing the board to scroll instead of clipping enlarged content.
    private var dynamicTypeContentScale: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 1.35 : 1
    }

    // MARK: - Empty state

    @ViewBuilder
    private func emptyState(device: SBDeviceClass, boardHasPanels: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(SBTheme.accent)
            Text(boardHasPanels ? "Nothing shown on \(device.displayName)"
                                : "This board is empty")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(SBTheme.textPrimary)
            Text(boardHasPanels
                 ? "Every panel on this board is hidden on \(device.displayName)."
                 : Self.emptyStateHint)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(SBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            #if !os(tvOS) && !os(watchOS)
            if !boardHasPanels {
                Menu {
                    ForEach(PanelKind.allCases) { kind in
                        Button {
                            if let panel = model.store.addPanel(kind: kind, to: dashboardID) {
                                model.isEditing = true
                                model.selectedPanelID = panel.id
                                model.inspectedPanelID = panel.id
                            }
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("Add a Panel", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(SBTheme.accent, in: Capsule())
                        .foregroundStyle(SBTheme.background)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            #endif
        }
        .accessibilityElement(children: .contain)
    }

    private static var emptyStateHint: String {
        #if os(tvOS)
        return "Add panels on your iPhone, iPad, or Mac — they sync here over iCloud."
        #elseif os(watchOS)
        return "Add panels on your iPhone or Mac — they sync here over iCloud."
        #else
        return "Add a panel to start watching something: a graph fed by your Mac, a web clip, a service check, or the weather."
        #endif
    }

    // MARK: - Panel cell

    @ViewBuilder
    private func panelCell(_ panel: Panel, board: Dashboard, device: SBDeviceClass,
                           grid: BoardGrid,
                           cellWidth: CGFloat, cellHeight: CGFloat,
                           boardSize: CGSize) -> some View {
        let isDragging = draggingPanelID == panel.id
        let isResizing = resizingPanelID == panel.id
        // While a gesture is in flight the panel is drawn at the frame that
        // gesture is about to commit, not at the one it still has in the store.
        let frame = (isDragging || isResizing) ? (gestureFrame ?? panel.frame) : panel.frame
        let width = CGFloat(frame.width) * cellWidth - spacing
        let height = CGFloat(frame.height) * cellHeight - spacing
        let origin = CGPoint(x: CGFloat(frame.x) * cellWidth + spacing,
                             y: CGFloat(frame.y) * cellHeight + spacing)
        // Where this panel sits on the board, so a panel masking the board's
        // backdrop lines up with its neighbours. The board's own padding is
        // added back because the backdrop is drawn behind it.
        let backdrop = SBBoardBackdrop(
            appearance: board.appearance,
            boardSize: CGSize(width: boardSize.width + spacing * 2,
                              height: boardSize.height + spacing * 2),
            panelOrigin: CGPoint(x: origin.x + spacing, y: origin.y + spacing))

        PanelView(panel: panel,
                  record: model.snapshots.record(for: panel.snapshotKey),
                  boardAppearance: board.appearance)
            .environment(\.sbBoardBackdrop, backdrop)
            .frame(width: max(40, width), height: max(40, height))
            #if !os(tvOS) && !os(watchOS)
            // Gestures attach below the editing overlay so its gear/delete
            // buttons and resize grips stay clickable while editing. High
            // priority because a board taller than the screen sits inside a
            // ScrollView, and the scroll would otherwise swallow every drag
            // before the panel saw it — nothing below the fold could be
            // rearranged at all.
            .highPriorityGesture(moveGesture(panel, device: device, grid: grid,
                                             cellWidth: cellWidth,
                                             cellHeight: cellHeight),
                                 including: isEditing ? .all : .subviews)
            #if os(macOS)
            // An open hand over a panel that can be picked up, so it reads as
            // draggable before anyone tries.
            .pointerStyle(isEditing ? (isDragging ? .grabActive : .grabIdle) : nil)
            #endif
            // The classic Status Board gesture: triple-tap force-reloads a panel.
            .onTapGesture(count: 3) {
                if !isPreview, panel.kind.isFetched { model.engine.refreshNow(panel: panel) }
            }
            .onTapGesture {
                if isEditing { model.selectedPanelID = panel.id }
            }
            .contextMenu { if !isPreview { panelContextMenu(panel) } }
            .accessibilityAction(named: Text("Configure")) {
                if !isPreview { model.inspectedPanelID = panel.id }
            }
            .accessibilityAction(named: Text("Refresh")) {
                if !isPreview, panel.kind.isFetched { model.engine.refreshNow(panel: panel) }
            }
            #endif
            .overlay {
                if isEditing {
                    editingOverlay(panel, device: device, grid: grid,
                                   cellWidth: cellWidth, cellHeight: cellHeight,
                                   panelSize: CGSize(width: max(40, width),
                                                     height: max(40, height)))
                }
            }
            .overlay {
                if isEditing && model.selectedPanelID == panel.id {
                    RoundedRectangle(cornerRadius: SBTheme.panelCornerRadius,
                                     style: .continuous)
                        .strokeBorder(SBTheme.secondaryAccent, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .offset(x: origin.x, y: origin.y)
            // A panel being moved or resized is lifted off the board, so it is
            // obvious which one the gesture has hold of when it passes over its
            // neighbours.
            .shadow(color: .black.opacity(0.5),
                    radius: isDragging || isResizing ? 20 : 0,
                    y: isDragging || isResizing ? 10 : 0)
            // Panels are allowed to overlap — a new one lands on top of its
            // neighbours rather than squeezing the board into another row — so
            // the selected panel is lifted above the stack. Without that, a
            // panel someone has just covered can't be clicked to drag back out.
            .zIndex(isDragging || isResizing ? 10
                    : (model.selectedPanelID == panel.id ? 5 : 0))
            // Short enough to keep up with a finger, long enough that the panel
            // slides between cells instead of teleporting.
            .animation(.snappy(duration: 0.15), value: frame)
            // Deliberately not focusable on tvOS: panels are read-only there, and
            // a focusable panel would swallow the remote's swipe-down before
            // TVRootView could open the menu.
    }

    #if !os(tvOS) && !os(watchOS)
    @ViewBuilder
    private func panelContextMenu(_ panel: Panel) -> some View {
        Button {
            model.inspectedPanelID = panel.id
        } label: {
            Label("Configure…", systemImage: "slider.horizontal.3")
        }
        if panel.kind.isFetched {
            Button {
                model.engine.refreshNow(panel: panel)
            } label: {
                Label("Refresh Now", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        Button {
            if let copy = model.store.duplicatePanel(id: panel.id, in: dashboardID) {
                model.selectedPanelID = copy.id
            }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            PanelPasteboard.copy(panel)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if model.store.dashboards.count > 1 {
            Menu {
                ForEach(model.store.dashboards.filter { $0.id != dashboardID }) { target in
                    Button {
                        _ = model.store.sharePanel(id: panel.id, from: dashboardID, to: target.id)
                    } label: {
                        if model.store.dashboardContainsSharedPanel(panel, dashboardID: target.id) {
                            Label(target.name, systemImage: "checkmark")
                        } else {
                            Text(target.name)
                        }
                    }
                    .disabled(model.store.dashboardContainsSharedPanel(panel,
                                                                       dashboardID: target.id))
                }
            } label: {
                Label("Share on Dashboard", systemImage: "rectangle.on.rectangle.angled")
            }
        }
        if panel.isSharedAcrossDashboards {
            Button {
                model.store.unlinkPanel(id: panel.id, in: dashboardID)
            } label: {
                Label("Make Independent", systemImage: "link.badge.plus")
            }
        }
        Divider()
        Button(role: .destructive) {
            model.store.removePanel(id: panel.id, from: dashboardID)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    #endif

    // MARK: - Editing chrome

    @ViewBuilder
    private func editingOverlay(_ panel: Panel, device: SBDeviceClass, grid: BoardGrid,
                                cellWidth: CGFloat, cellHeight: CGFloat,
                                panelSize: CGSize) -> some View {
        RoundedRectangle(cornerRadius: SBTheme.panelCornerRadius, style: .continuous)
            .strokeBorder(SBTheme.accent.opacity(0.7), lineWidth: 2)
        #if !os(tvOS) && !os(watchOS)
        // Configure and delete sit together at the top edge rather than in the
        // two top corners, which now belong to the resize grips.
        VStack {
            HStack(spacing: 8 * controlScale) {
                Button {
                    model.inspectedPanelID = panel.id
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12 * controlScale, weight: .bold))
                        .foregroundStyle(SBTheme.background)
                        .padding(6 * controlScale)
                        .background(SBTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(panel.title)")
                Button {
                    model.store.removePanel(id: panel.id, from: dashboardID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12 * controlScale, weight: .bold))
                        .foregroundStyle(SBTheme.textPrimary)
                        .padding(6 * controlScale)
                        .background(SBTheme.bad, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(panel.title)")
            }
            Spacer(minLength: 0)
        }
        .padding(6 * controlScale)

        // Grips only on the panel being worked on. Four grips on every panel of
        // a busy board is a thicket of targets, and hiding them until a panel is
        // picked means each one can be as big as it needs to be.
        if model.selectedPanelID == panel.id {
            ForEach(SBResizeCorner.allCases, id: \.self) { corner in
                resizeGrip(corner, panel: panel, device: device, grid: grid,
                           cellWidth: cellWidth, cellHeight: cellHeight,
                           panelSize: panelSize)
            }
        }
        #endif
    }

    #if !os(tvOS) && !os(watchOS)
    /// How wide a grip's invisible target is. A pointer can be aimed, so the
    /// Mac gets a smaller one that leaves more of the panel free to drag;
    /// a fingertip cannot, so touch screens get the full 44 points.
    #if os(macOS)
    private static let gripTargetSize: CGFloat = 30
    #else
    private static let gripTargetSize: CGFloat = 44
    #endif

    /// One corner grip: a small visible dot centred on the corner, with a much
    /// larger invisible target around it. Straddling the corner rather than
    /// sitting inside it means the grip costs the panel almost no room, and half
    /// the target is out over the gap between panels where nothing competes for
    /// the drag.
    private func resizeGrip(_ corner: SBResizeCorner, panel: Panel,
                            device: SBDeviceClass, grid: BoardGrid,
                            cellWidth: CGFloat, cellHeight: CGFloat,
                            panelSize: CGSize) -> some View {
        let dot = 13 * controlScale
        // Never so large that the four targets meet in the middle of a small
        // panel and leave nowhere to grab it for a move.
        let target = min(Self.gripTargetSize * controlScale,
                         max(dot, min(panelSize.width, panelSize.height) * 0.45))
        return Circle()
            .fill(SBTheme.secondaryAccent)
            .overlay { Circle().strokeBorder(SBTheme.background.opacity(0.9), lineWidth: 2) }
            .frame(width: dot, height: dot)
            .frame(width: target, height: target)
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture(panel, corner: corner, device: device,
                                               grid: grid, cellWidth: cellWidth,
                                               cellHeight: cellHeight))
            #if os(macOS)
            .pointerStyle(.frameResize(position: corner.pointerPosition))
            #endif
            .offset(x: (corner.movesLeadingEdge ? -target : target) / 2,
                    y: (corner.movesTopEdge ? -target : target) / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .accessibilityLabel("Resize \(panel.title) from the \(corner.displayName)")
            .accessibilityHint("Drag to change the panel's size")
    }
    #endif

    // MARK: - Gestures

    #if !os(tvOS) && !os(watchOS)
    /// Where a move would land, in whole grid cells. The live preview and the
    /// commit both come from this, so the two can never disagree.
    private func movedFrame(_ translation: CGSize, from frame: GridRect,
                            grid: BoardGrid,
                            cellWidth: CGFloat, cellHeight: CGFloat) -> GridRect {
        var moved = frame
        moved.x += Int((translation.width / cellWidth).rounded())
        moved.y += Int((translation.height / cellHeight).rounded())
        return moved.clamped(to: grid)
    }

    /// Where a resize would land. Pulling a bottom or trailing corner leaves the
    /// origin where it is and changes the size; pulling a top or leading corner
    /// moves that edge instead and lets the opposite one stay put, so a panel can
    /// be grown upwards and to the left as well.
    private func resizedFrame(_ translation: CGSize, from frame: GridRect,
                              corner: SBResizeCorner, grid: BoardGrid,
                              cellWidth: CGFloat, cellHeight: CGFloat) -> GridRect {
        var resized = frame
        let columns = Int((translation.width / cellWidth).rounded())
        let rows = Int((translation.height / cellHeight).rounded())
        if corner.movesLeadingEdge {
            // The right edge is pinned, so the left one may travel anywhere from
            // the board's edge up to one cell short of it.
            resized.x = min(max(0, frame.x + columns), frame.x + frame.width - 1)
            resized.width = frame.x + frame.width - resized.x
        } else {
            resized.width = min(max(1, frame.width + columns),
                                max(1, grid.columns - frame.x))
        }
        if corner.movesTopEdge {
            resized.y = min(max(0, frame.y + rows), frame.y + frame.height - 1)
            resized.height = frame.y + frame.height - resized.y
        } else {
            resized.height = min(max(1, frame.height + rows),
                                 max(1, grid.rows - frame.y))
        }
        return resized
    }

    // Both gestures preview in whole cells rather than following the pointer
    // freely, and that is not just cosmetic. The store update and the @State
    // reset land in *different* SwiftUI transactions, so there is one frame
    // where the panel renders at its newly committed frame with the gesture's
    // own still applied — it visibly jumps past the drop point and snaps back.
    // Drawing the panel at the frame that is about to be committed makes those
    // two numerically identical, so the panel is in the right place whichever
    // update SwiftUI processes first.

    private func moveGesture(_ panel: Panel, device: SBDeviceClass, grid: BoardGrid,
                             cellWidth: CGFloat, cellHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                if draggingPanelID != panel.id {
                    draggingPanelID = panel.id
                    // Picking a panel up selects it, so its resize grips are
                    // there the moment it is put down.
                    model.selectedPanelID = panel.id
                }
                gestureFrame = movedFrame(value.translation, from: panel.frame, grid: grid,
                                          cellWidth: cellWidth, cellHeight: cellHeight)
            }
            .onEnded { value in
                defer {
                    draggingPanelID = nil
                    gestureFrame = nil
                }
                commit(movedFrame(value.translation, from: panel.frame, grid: grid,
                                  cellWidth: cellWidth, cellHeight: cellHeight),
                       for: panel, on: device)
            }
    }

    private func resizeGesture(_ panel: Panel, corner: SBResizeCorner,
                               device: SBDeviceClass, grid: BoardGrid,
                               cellWidth: CGFloat, cellHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                resizingPanelID = panel.id
                gestureFrame = resizedFrame(value.translation, from: panel.frame,
                                            corner: corner, grid: grid,
                                            cellWidth: cellWidth, cellHeight: cellHeight)
            }
            .onEnded { value in
                defer {
                    resizingPanelID = nil
                    gestureFrame = nil
                }
                commit(resizedFrame(value.translation, from: panel.frame, corner: corner,
                                    grid: grid, cellWidth: cellWidth, cellHeight: cellHeight),
                       for: panel, on: device)
            }
    }

    /// Moves or resizes the selected panel by one cell from the keyboard. Arrow
    /// keys move it, Option-arrow resizes it — a way to place a panel exactly
    /// that doesn't depend on landing a drag, and the only way at all when the
    /// board is scaled down small in the device simulator.
    private func nudge(_ key: KeyEquivalent, resizing: Bool, panels: [Panel],
                       device: SBDeviceClass, grid: BoardGrid) -> KeyPress.Result {
        guard isEditing, let id = model.selectedPanelID,
              let panel = panels.first(where: { $0.id == id }) else { return .ignored }
        var frame = panel.frame
        if resizing {
            switch key {
            case .leftArrow: frame.width = max(1, frame.width - 1)
            case .rightArrow: frame.width = min(frame.width + 1, max(1, grid.columns - frame.x))
            case .upArrow: frame.height = max(1, frame.height - 1)
            case .downArrow: frame.height = min(frame.height + 1, max(1, grid.rows - frame.y))
            default: return .ignored
            }
        } else {
            switch key {
            case .leftArrow: frame.x -= 1
            case .rightArrow: frame.x += 1
            case .upArrow: frame.y -= 1
            case .downArrow: frame.y += 1
            default: return .ignored
            }
            frame = frame.clamped(to: grid)
        }
        guard frame != panel.frame else { return .handled }
        commit(frame, for: panel, on: device)
        return .handled
    }

    /// Writes a new frame where it belongs: into this device's own layout when
    /// one exists, when the simulator is editing another screen, or when this
    /// screen arranges itself — a drag on a phone has to land in the phone's
    /// layout, because the shared one is not what the phone is showing.
    /// Otherwise it goes into the shared layout every device follows.
    private func commit(_ frame: GridRect, for panel: Panel, on device: SBDeviceClass) {
        let board = model.store.dashboard(id: dashboardID)
        let usesOverride = layoutTarget != nil
            || device.usesAutomaticLayout
            || (board?.hasCustomLayout(for: device) ?? false)
        if usesOverride {
            model.store.setPanelFrame(frame, panelID: panel.id,
                                      in: dashboardID, on: device)
        } else {
            var updated = panel
            updated.frame = frame
            model.store.updatePanel(updated, in: dashboardID)
        }
    }
    #endif

    private func gridGuides(grid: BoardGrid, cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        Canvas { context, size in
            var path = Path()
            for column in 0...grid.columns {
                let x = CGFloat(column) * cellWidth + spacing / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...grid.rows {
                let y = CGFloat(row) * cellHeight + spacing / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(SBTheme.panelBorder.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
