import Foundation
import Observation

/// Owns the list of dashboards, persists them locally, and notifies the sync
/// engine about local edits.
@MainActor
@Observable
public final class DashboardStore {
    public private(set) var dashboards: [Dashboard] = []
    public var selectedDashboardID: Dashboard.ID?

    /// Sync hooks — set by CloudSyncEngine.
    @ObservationIgnored public var onLocalSave: ((Dashboard) -> Void)?
    @ObservationIgnored public var onLocalDelete: ((Dashboard.ID) -> Void)?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    // MARK: - Undo

    struct UndoEntry {
        var dashboards: [Dashboard]
        var selectedDashboardID: Dashboard.ID?
        var actionName: String
    }

    private static let undoLimit = 40

    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    /// True while applying an undo/redo, so those restores don't record more
    /// undo entries.
    @ObservationIgnored private var isApplyingHistory = false

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.actionName }
    public var redoActionName: String? { redoStack.last?.actionName }

    /// Records the current state before a user-initiated change.
    private func recordUndo(_ actionName: String) {
        guard !isApplyingHistory else { return }
        undoStack.append(UndoEntry(dashboards: dashboards,
                                   selectedDashboardID: selectedDashboardID,
                                   actionName: actionName))
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
    }

    public func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(dashboards: dashboards,
                                   selectedDashboardID: selectedDashboardID,
                                   actionName: entry.actionName))
        restore(entry)
    }

    public func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(dashboards: dashboards,
                                   selectedDashboardID: selectedDashboardID,
                                   actionName: entry.actionName))
        restore(entry)
    }

    private func restore(_ entry: UndoEntry) {
        let previousIDs = Set(dashboards.map(\.id))
        isApplyingHistory = true
        dashboards = entry.dashboards
        selectedDashboardID = entry.selectedDashboardID
            ?? entry.dashboards.first?.id
        isApplyingHistory = false

        // Keep iCloud in step: re-save what's here now, delete what went away.
        let restoredIDs = Set(entry.dashboards.map(\.id))
        for board in entry.dashboards {
            onLocalSave?(board)
        }
        for removed in previousIDs.subtracting(restoredIDs) {
            onLocalDelete?(removed)
        }
        scheduleSave()
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? SBStorage.localSupportURL().appendingPathComponent("dashboards.json")
        load()
    }

    public var selectedDashboard: Dashboard? {
        get {
            guard let id = selectedDashboardID else { return dashboards.first }
            return dashboards.first { $0.id == id }
        }
        set {
            guard let board = newValue else { return }
            update(board)
        }
    }

    public func dashboard(id: Dashboard.ID) -> Dashboard? {
        dashboards.first { $0.id == id }
    }

    // MARK: - Mutations

    public func add(_ dashboard: Dashboard) {
        recordUndo("Add \(dashboard.name)")
        dashboards.append(dashboard)
        selectedDashboardID = dashboard.id
        didEdit(dashboard)
    }

    public func update(_ dashboard: Dashboard, touchModified: Bool = true,
                       undoActionName: String = "Edit Board") {
        guard let index = dashboards.firstIndex(where: { $0.id == dashboard.id }) else { return }
        var board = dashboard
        if touchModified { board.modifiedAt = Date() }
        guard board != dashboards[index] else { return }
        recordUndo(undoActionName)
        dashboards[index] = board
        didEdit(board)
    }

    public func delete(id: Dashboard.ID) {
        guard let board = dashboards.first(where: { $0.id == id }) else { return }
        recordUndo("Delete \(board.name)")
        dashboards.removeAll { $0.id == id }
        if selectedDashboardID == id { selectedDashboardID = dashboards.first?.id }
        scheduleSave()
        onLocalDelete?(id)
    }

    // MARK: - Panel helpers

    public func updatePanel(_ panel: Panel, in dashboardID: Dashboard.ID) {
        guard var board = dashboard(id: dashboardID),
              let index = board.panels.firstIndex(where: { $0.id == panel.id }) else { return }
        board.panels[index] = panel
        update(board, undoActionName: "Edit \(panel.title)")
    }

    public func addPanel(kind: PanelKind, to dashboardID: Dashboard.ID) -> Panel? {
        guard var board = dashboard(id: dashboardID) else { return nil }
        let size = kind.defaultSize
        let panel = Panel(kind: kind, title: kind.displayName,
                          frame: board.makeRoom(width: size.width, height: size.height))
        board.panels.append(panel)
        update(board, undoActionName: "Add \(kind.displayName)")
        return panel
    }

    /// Copies a panel into the same board, placed in the first free slot.
    @discardableResult
    public func duplicatePanel(id: Panel.ID, in dashboardID: Dashboard.ID) -> Panel? {
        guard var board = dashboard(id: dashboardID),
              let original = board.panels.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.frame = board.makeRoom(width: original.frame.width,
                                    height: original.frame.height)
        board.panels.append(copy)
        update(board, undoActionName: "Duplicate \(original.title)")
        return copy
    }

    /// Inserts a panel decoded from the pasteboard, re-homing it into a free
    /// slot and giving it a fresh identity.
    @discardableResult
    public func insertPanel(_ panel: Panel, into dashboardID: Dashboard.ID) -> Panel? {
        guard var board = dashboard(id: dashboardID) else { return nil }
        var inserted = panel
        inserted.id = UUID()
        inserted.frame = board.makeRoom(width: panel.frame.width,
                                        height: panel.frame.height)
        board.panels.append(inserted)
        update(board, undoActionName: "Paste \(panel.title)")
        return inserted
    }

    // MARK: - Per-device layouts

    /// Moves or resizes a panel on one device's layout, leaving the shared
    /// layout — and therefore every other device — untouched.
    public func setPanelFrame(_ frame: GridRect, panelID: Panel.ID,
                              in dashboardID: Dashboard.ID, on device: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID) else { return }
        let name = board.panels.first { $0.id == panelID }?.title ?? "Panel"
        board.setFrame(frame, for: panelID, on: device)
        update(board, undoActionName: "Move \(name) on \(device.displayName)")
    }

    public func setPanelHidden(_ hidden: Bool, panelID: Panel.ID,
                               in dashboardID: Dashboard.ID, on device: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID) else { return }
        let name = board.panels.first { $0.id == panelID }?.title ?? "Panel"
        board.setHidden(hidden, for: panelID, on: device)
        update(board,
               undoActionName: "\(hidden ? "Hide" : "Show") \(name) on \(device.displayName)")
    }

    public func setGrid(_ grid: BoardGrid, in dashboardID: Dashboard.ID,
                        on device: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID) else { return }
        board.setGrid(grid, on: device)
        update(board, undoActionName: "Resize \(device.displayName) Grid")
    }

    public func beginCustomLayout(in dashboardID: Dashboard.ID, on device: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID),
              !board.hasCustomLayout(for: device) else { return }
        board.beginCustomLayout(for: device)
        update(board, undoActionName: "Customize \(device.displayName) Layout")
    }

    public func resetLayout(in dashboardID: Dashboard.ID, on device: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID) else { return }
        board.resetLayout(for: device)
        update(board, undoActionName: "Reset \(device.displayName) Layout")
    }

    public func copyLayout(in dashboardID: Dashboard.ID,
                           from source: SBDeviceClass, to target: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID) else { return }
        board.copyLayout(from: source, to: target)
        update(board, undoActionName: "Copy \(source.displayName) Layout")
    }

    public func autoArrange(in dashboardID: Dashboard.ID, on device: SBDeviceClass) {
        guard var board = dashboard(id: dashboardID) else { return }
        board.autoArrange(for: device)
        update(board, undoActionName: "Auto-Arrange for \(device.displayName)")
    }

    public func removePanel(id: Panel.ID, from dashboardID: Dashboard.ID) {
        guard var board = dashboard(id: dashboardID) else { return }
        let name = board.panels.first { $0.id == id }?.title ?? "Panel"
        board.panels.removeAll { $0.id == id }
        update(board, undoActionName: "Delete \(name)")
    }

    /// All panels across every dashboard (the refresh engine deduplicates work).
    public var allPanels: [Panel] {
        dashboards.flatMap(\.panels)
    }

    // MARK: - Sync ingestion

    /// Applies a dashboard that arrived from iCloud. Last-writer-wins on
    /// `modifiedAt`; does not re-trigger sync.
    public func applyRemote(_ dashboard: Dashboard) {
        if let index = dashboards.firstIndex(where: { $0.id == dashboard.id }) {
            guard dashboard.modifiedAt >= dashboards[index].modifiedAt else { return }
            dashboards[index] = dashboard
        } else {
            dashboards.append(dashboard)
        }
        scheduleSave()
    }

    public func applyRemoteDeletion(id: Dashboard.ID) {
        dashboards.removeAll { $0.id == id }
        if selectedDashboardID == id { selectedDashboardID = dashboards.first?.id }
        scheduleSave()
    }

    // MARK: - Persistence

    private func didEdit(_ dashboard: Dashboard) {
        scheduleSave()
        onLocalSave?(dashboard)
    }

    private func load() {
        if let saved = SBStorage.read([Dashboard].self, from: fileURL), !saved.isEmpty {
            dashboards = saved
        } else {
            dashboards = [.starter()]
        }
        selectedDashboardID = dashboards.first?.id
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let boards = dashboards
        let url = fileURL
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            SBStorage.write(boards, to: url)
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        SBStorage.write(dashboards, to: fileURL)
    }
}
