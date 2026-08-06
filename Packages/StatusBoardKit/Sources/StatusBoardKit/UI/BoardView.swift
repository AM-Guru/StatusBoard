import SwiftUI

/// Renders one dashboard as a grid of panels. On iOS/macOS an edit mode
/// enables drag-to-move, drag-to-resize, configure, and delete; tvOS is
/// display-only with focus effects.
public struct BoardView: View {
    let model: AppModel
    let dashboardID: Dashboard.ID

    @State private var draggingPanelID: Panel.ID?
    @State private var dragOffset: CGSize = .zero
    @State private var resizingPanelID: Panel.ID?
    @State private var resizeDelta: CGSize = .zero

    private let spacing: CGFloat = 10

    public init(model: AppModel, dashboardID: Dashboard.ID) {
        self.model = model
        self.dashboardID = dashboardID
    }

    public var body: some View {
        GeometryReader { proxy in
            if let board = model.store.dashboard(id: dashboardID) {
                let cellWidth = (proxy.size.width - spacing) / CGFloat(board.grid.columns)
                let cellHeight = (proxy.size.height - spacing) / CGFloat(board.grid.rows)
                ZStack(alignment: .topLeading) {
                    if model.isEditing {
                        gridGuides(board: board, cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    ForEach(board.panels) { panel in
                        panelCell(panel, board: board,
                                  cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    if board.panels.isEmpty {
                        emptyState
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
        }
        .padding(spacing)
        .background(SBTheme.background.ignoresSafeArea())
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(SBTheme.accent)
            Text("This board is empty")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(SBTheme.textPrimary)
            Text(Self.emptyStateHint)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(SBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            #if !os(tvOS) && !os(watchOS)
            Menu {
                ForEach(PanelKind.allCases) { kind in
                    Button {
                        if let panel = model.store.addPanel(kind: kind, to: dashboardID) {
                            model.isEditing = true
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
    private func panelCell(_ panel: Panel, board: Dashboard,
                           cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        let frame = panel.frame
        let width = CGFloat(frame.width) * cellWidth - spacing
        let height = CGFloat(frame.height) * cellHeight - spacing
        let origin = CGPoint(x: CGFloat(frame.x) * cellWidth + spacing,
                             y: CGFloat(frame.y) * cellHeight + spacing)
        let isDragging = draggingPanelID == panel.id
        let isResizing = resizingPanelID == panel.id

        PanelView(panel: panel, record: model.snapshots.record(for: panel.snapshotKey))
            .frame(width: max(40, width + (isResizing ? resizeDelta.width : 0)),
                   height: max(40, height + (isResizing ? resizeDelta.height : 0)))
            #if !os(tvOS) && !os(watchOS)
            // Gestures attach below the editing overlay so its gear/delete
            // buttons stay clickable while editing.
            .gesture(model.isEditing ? moveGesture(panel, board: board,
                                                   cellWidth: cellWidth,
                                                   cellHeight: cellHeight) : nil)
            // The classic Status Board gesture: triple-tap force-reloads a panel.
            .onTapGesture(count: 3) {
                if panel.kind.isFetched { model.engine.refreshNow(panel: panel) }
            }
            .onTapGesture {
                if model.isEditing { model.selectedPanelID = panel.id }
            }
            .contextMenu { panelContextMenu(panel) }
            #endif
            .overlay {
                if model.isEditing {
                    editingOverlay(panel, board: board,
                                   cellWidth: cellWidth, cellHeight: cellHeight)
                }
            }
            .overlay {
                if model.isEditing && model.selectedPanelID == panel.id {
                    RoundedRectangle(cornerRadius: SBTheme.panelCornerRadius,
                                     style: .continuous)
                        .strokeBorder(SBTheme.secondaryAccent, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .offset(x: origin.x + (isDragging ? dragOffset.width : 0),
                    y: origin.y + (isDragging ? dragOffset.height : 0))
            .zIndex(isDragging || isResizing ? 10 : 0)
            .animation(.snappy(duration: 0.2), value: panel.frame)
            #if os(tvOS)
            .focusable()
            #endif
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
            model.store.duplicatePanel(id: panel.id, in: dashboardID)
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
    private func editingOverlay(_ panel: Panel, board: Dashboard,
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
                    .gesture(resizeGesture(panel, board: board,
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
    private func moveGesture(_ panel: Panel, board: Dashboard,
                             cellWidth: CGFloat, cellHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggingPanelID = panel.id
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    draggingPanelID = nil
                    dragOffset = .zero
                }
                var updated = panel
                updated.frame.x += Int((value.translation.width / cellWidth).rounded())
                updated.frame.y += Int((value.translation.height / cellHeight).rounded())
                updated.frame = updated.frame.clamped(to: board.grid)
                model.store.updatePanel(updated, in: dashboardID)
            }
    }

    private func resizeGesture(_ panel: Panel, board: Dashboard,
                               cellWidth: CGFloat, cellHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                resizingPanelID = panel.id
                resizeDelta = value.translation
            }
            .onEnded { value in
                defer {
                    resizingPanelID = nil
                    resizeDelta = .zero
                }
                var updated = panel
                updated.frame.width = max(1, updated.frame.width + Int((value.translation.width / cellWidth).rounded()))
                updated.frame.height = max(1, updated.frame.height + Int((value.translation.height / cellHeight).rounded()))
                updated.frame = updated.frame.clamped(to: board.grid)
                model.store.updatePanel(updated, in: dashboardID)
            }
    }
    #endif

    private func gridGuides(board: Dashboard, cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        Canvas { context, size in
            var path = Path()
            for column in 0...board.grid.columns {
                let x = CGFloat(column) * cellWidth + spacing / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...board.grid.rows {
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
