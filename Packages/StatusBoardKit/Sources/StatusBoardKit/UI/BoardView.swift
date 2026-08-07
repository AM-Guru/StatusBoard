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
    @State private var dragOffset: CGSize = .zero
    @State private var resizingPanelID: Panel.ID?
    @State private var resizeDelta: CGSize = .zero

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

    /// The screen being laid out — the simulator's target, or this device.
    private var device: SBDeviceClass { layoutTarget ?? .current }

    private var isEditing: Bool { editingOverride ?? model.isEditing }

    public var body: some View {
        let boardAppearance = model.store.dashboard(id: dashboardID)?.appearance ?? BoardAppearance()
        GeometryReader { proxy in
            if let board = model.store.dashboard(id: dashboardID) {
                let grid = board.grid(for: device)
                let panels = board.panels(for: device)
                let cellWidth = (proxy.size.width - spacing) / CGFloat(max(1, grid.columns))
                let cellHeight = (proxy.size.height - spacing) / CGFloat(max(1, grid.rows))
                ZStack(alignment: .topLeading) {
                    if isEditing {
                        gridGuides(grid: grid, cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    ForEach(panels) { panel in
                        panelCell(panel, board: board, grid: grid,
                                  cellWidth: cellWidth, cellHeight: cellHeight,
                                  boardSize: proxy.size)
                    }
                    if panels.isEmpty {
                        emptyState(boardHasPanels: !board.panels.isEmpty)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .coordinateSpace(.named(Self.boardSpace))
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

    // MARK: - Empty state

    @ViewBuilder
    private func emptyState(boardHasPanels: Bool) -> some View {
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
    private func panelCell(_ panel: Panel, board: Dashboard, grid: BoardGrid,
                           cellWidth: CGFloat, cellHeight: CGFloat,
                           boardSize: CGSize) -> some View {
        let frame = panel.frame
        let width = CGFloat(frame.width) * cellWidth - spacing
        let height = CGFloat(frame.height) * cellHeight - spacing
        let origin = CGPoint(x: CGFloat(frame.x) * cellWidth + spacing,
                             y: CGFloat(frame.y) * cellHeight + spacing)
        let isDragging = draggingPanelID == panel.id
        let isResizing = resizingPanelID == panel.id
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
            .frame(width: max(40, width + (isResizing ? resizeDelta.width : 0)),
                   height: max(40, height + (isResizing ? resizeDelta.height : 0)))
            #if !os(tvOS) && !os(watchOS)
            // Gestures attach below the editing overlay so its gear/delete
            // buttons stay clickable while editing.
            .gesture(isEditing ? moveGesture(panel, grid: grid,
                                             cellWidth: cellWidth,
                                             cellHeight: cellHeight) : nil)
            // The classic Status Board gesture: triple-tap force-reloads a panel.
            .onTapGesture(count: 3) {
                if !isPreview, panel.kind.isFetched { model.engine.refreshNow(panel: panel) }
            }
            .onTapGesture {
                if isEditing { model.selectedPanelID = panel.id }
            }
            .contextMenu { if !isPreview { panelContextMenu(panel) } }
            #endif
            .overlay {
                if isEditing {
                    editingOverlay(panel, grid: grid,
                                   cellWidth: cellWidth, cellHeight: cellHeight)
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
            .offset(x: origin.x + (isDragging ? dragOffset.width : 0),
                    y: origin.y + (isDragging ? dragOffset.height : 0))
            // Panels are allowed to overlap — a new one lands on top of its
            // neighbours rather than squeezing the board into another row — so
            // the selected panel is lifted above the stack. Without that, a
            // panel someone has just covered can't be clicked to drag back out.
            .zIndex(isDragging || isResizing ? 10
                    : (model.selectedPanelID == panel.id ? 5 : 0))
            .animation(.snappy(duration: 0.2), value: panel.frame)
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
    private func editingOverlay(_ panel: Panel, grid: BoardGrid,
                                cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: SBTheme.panelCornerRadius, style: .continuous)
            .strokeBorder(SBTheme.accent.opacity(0.7), lineWidth: 2)
        #if !os(tvOS) && !os(watchOS)
        VStack {
            HStack {
                Button {
                    model.inspectedPanelID = panel.id
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SBTheme.background)
                        .padding(6)
                        .background(SBTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(panel.title)")
                Spacer()
                Button {
                    model.store.removePanel(id: panel.id, from: dashboardID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SBTheme.textPrimary)
                        .padding(6)
                        .background(SBTheme.bad, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(panel.title)")
            }
            Spacer()
            HStack {
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SBTheme.background)
                    .padding(6)
                    .background(SBTheme.secondaryAccent, in: Circle())
                    .gesture(resizeGesture(panel, grid: grid,
                                           cellWidth: cellWidth, cellHeight: cellHeight))
                    .accessibilityLabel("Resize \(panel.title)")
                    .accessibilityHint("Drag to change the panel's size")
            }
        }
        .padding(6)
        #endif
    }

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

    /// Where a resize would land. The origin is pinned — dragging the handle
    /// changes the panel's size, never its top-left corner — so the preview,
    /// which only grows the frame, matches what gets committed.
    private func resizedFrame(_ translation: CGSize, from frame: GridRect,
                              grid: BoardGrid,
                              cellWidth: CGFloat, cellHeight: CGFloat) -> GridRect {
        var resized = frame
        resized.width = min(max(1, frame.width + Int((translation.width / cellWidth).rounded())),
                            max(1, grid.columns - frame.x))
        resized.height = min(max(1, frame.height + Int((translation.height / cellHeight).rounded())),
                             max(1, grid.rows - frame.y))
        return resized
    }

    // Both gestures preview in whole cells rather than following the pointer
    // freely, and that is not just cosmetic. The store update and the @State
    // reset land in *different* SwiftUI transactions, so there is one frame
    // where the panel renders at its newly committed origin with the old drag
    // offset still applied — it visibly jumps past the drop point and snaps
    // back. Previewing the frame that is about to be committed makes those two
    // positions numerically identical, so that frame draws in the right place
    // whichever update SwiftUI processes first.

    private func moveGesture(_ panel: Panel, grid: BoardGrid,
                             cellWidth: CGFloat, cellHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                let target = movedFrame(value.translation, from: panel.frame, grid: grid,
                                        cellWidth: cellWidth, cellHeight: cellHeight)
                draggingPanelID = panel.id
                dragOffset = CGSize(
                    width: CGFloat(target.x - panel.frame.x) * cellWidth,
                    height: CGFloat(target.y - panel.frame.y) * cellHeight)
            }
            .onEnded { value in
                defer {
                    draggingPanelID = nil
                    dragOffset = .zero
                }
                commit(movedFrame(value.translation, from: panel.frame, grid: grid,
                                  cellWidth: cellWidth, cellHeight: cellHeight),
                       for: panel)
            }
    }

    private func resizeGesture(_ panel: Panel, grid: BoardGrid,
                               cellWidth: CGFloat, cellHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.boardSpace))
            .onChanged { value in
                let target = resizedFrame(value.translation, from: panel.frame, grid: grid,
                                          cellWidth: cellWidth, cellHeight: cellHeight)
                resizingPanelID = panel.id
                resizeDelta = CGSize(
                    width: CGFloat(target.width - panel.frame.width) * cellWidth,
                    height: CGFloat(target.height - panel.frame.height) * cellHeight)
            }
            .onEnded { value in
                defer {
                    resizingPanelID = nil
                    resizeDelta = .zero
                }
                commit(resizedFrame(value.translation, from: panel.frame, grid: grid,
                                    cellWidth: cellWidth, cellHeight: cellHeight),
                       for: panel)
            }
    }

    /// Writes a new frame where it belongs: into this device's own layout when
    /// one exists (or when the simulator is editing another screen), otherwise
    /// into the shared layout every device follows.
    private func commit(_ frame: GridRect, for panel: Panel) {
        let board = model.store.dashboard(id: dashboardID)
        let usesOverride = layoutTarget != nil
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
