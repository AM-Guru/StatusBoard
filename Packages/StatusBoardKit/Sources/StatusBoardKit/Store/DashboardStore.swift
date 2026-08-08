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
    /// Boards this device has actually seen in iCloud. Only meaningful on the
    /// display-only platforms, where it's what separates a real board from a
    /// leftover local one.
    @ObservationIgnored private let remoteIDsURL: URL
    @ObservationIgnored private var remoteKnownIDs: Set<UUID> = []
    /// The same idea for boards delivered by the Mac bridge. Kept apart from
    /// the iCloud set because the two sources disagree legitimately: the Mac
    /// not listing a board means "deleted" only for boards the Mac sent in the
    /// first place, never for one iCloud delivered from an iPhone the Mac
    /// hasn't synced with yet.
    @ObservationIgnored private let bridgeIDsURL: URL
    @ObservationIgnored private var bridgeKnownIDs: Set<UUID> = []
    /// Boards an *authoring* device has taken from the bridge, remembered for
    /// as long as the install lives — including after the user deletes one.
    ///
    /// Two jobs, and the second is why this outlives the board itself. It marks
    /// which local boards the Mac is allowed to update, so a board made on this
    /// iPhone is never touched by a Mac on the network. And it stops a board
    /// deleted here coming back on the Mac's next broadcast, which is what
    /// makes a purely additive merge safe to run every time one arrives.
    @ObservationIgnored private let bridgeAdoptedIDsURL: URL
    @ObservationIgnored private var bridgeAdoptedIDs: Set<UUID> = []

    /// Whether this device can create and edit boards at all.
    ///
    /// Apple TV and the Watch are displays: every board is built on a Mac,
    /// iPad or iPhone and arrives over iCloud. They must not invent a starter
    /// board of their own — that puts a board on screen that exists on none of
    /// the user's other devices (and an older build then uploaded it to
    /// iCloud, where it doesn't belong either).
    @ObservationIgnored public let authorsBoards: Bool

    nonisolated public static var platformAuthorsBoards: Bool {
        #if os(tvOS) || os(watchOS)
        return false
        #else
        return true
        #endif
    }

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

    public init(fileURL: URL? = nil, authorsBoards: Bool = DashboardStore.platformAuthorsBoards) {
        let url = fileURL
            ?? SBStorage.localSupportURL().appendingPathComponent("dashboards.json")
        self.fileURL = url
        self.authorsBoards = authorsBoards
        self.remoteIDsURL = url.deletingLastPathComponent()
            .appendingPathComponent("icloud-boards.json")
        self.bridgeIDsURL = url.deletingLastPathComponent()
            .appendingPathComponent("bridge-boards.json")
        self.bridgeAdoptedIDsURL = url.deletingLastPathComponent()
            .appendingPathComponent("bridge-adopted.json")
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

    /// Copies a board — panels, appearance and per-device layouts — and drops
    /// the copy in right after the original.
    @discardableResult
    public func duplicate(id: Dashboard.ID) -> Dashboard? {
        guard let index = dashboards.firstIndex(where: { $0.id == id }) else { return nil }
        let original = dashboards[index]
        let copy = original.duplicated(
            name: Self.copyName(for: original.name, taken: Set(dashboards.map(\.name))))
        recordUndo("Duplicate \(original.name)")
        dashboards.insert(copy, at: index + 1)
        selectedDashboardID = copy.id
        didEdit(copy)
        return copy
    }

    /// "Home" → "Home Copy" → "Home Copy 2", so duplicating twice doesn't leave
    /// two identically named boards in the sidebar.
    static func copyName(for name: String, taken: Set<String>) -> String {
        let base = "\(name) Copy"
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
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
        guard let linkID = panel.linkedContentID else {
            board.panels[index] = panel
            update(board, undoActionName: "Edit \(panel.title)")
            return
        }

        // One edit, one undo step, however many dashboard placements follow it.
        // Frames and placement IDs deliberately stay local; everything that
        // defines what the panel is and how it renders follows the shared copy.
        let now = Date()
        var edited = panel
        edited.linkedContentModifiedAt = now
        var pending: [(index: Int, board: Dashboard)] = []
        for (boardIndex, original) in dashboards.enumerated() {
            var candidate = original
            var changed = false
            for panelIndex in candidate.panels.indices
            where candidate.panels[panelIndex].linkedContentID == linkID {
                if candidate.id == dashboardID && candidate.panels[panelIndex].id == panel.id {
                    if candidate.panels[panelIndex] != edited {
                        candidate.panels[panelIndex] = edited
                        changed = true
                    }
                } else {
                    var follower = candidate.panels[panelIndex]
                    follower.kind = edited.kind
                    follower.title = edited.title
                    follower.settings = edited.settings
                    follower.linkedContentModifiedAt = now
                    if follower != candidate.panels[panelIndex] {
                        candidate.panels[panelIndex] = follower
                        changed = true
                    }
                }
            }
            guard changed else { continue }
            candidate.modifiedAt = now
            pending.append((boardIndex, candidate))
        }
        guard !pending.isEmpty else { return }
        recordUndo("Edit Shared \(panel.title)")
        for entry in pending {
            dashboards[entry.index] = entry.board
            didEdit(entry.board)
        }
    }

    public func addPanel(kind: PanelKind, to dashboardID: Dashboard.ID) -> Panel? {
        guard var board = dashboard(id: dashboardID) else { return nil }
        let size = kind.defaultSize
        var settings = PanelSettings()
        settings.refreshSeconds = kind.defaultRefreshSeconds
        let panel = Panel(kind: kind, title: kind.displayName,
                          frame: board.makeRoom(width: size.width, height: size.height),
                          settings: settings)
        board.panels.append(panel)
        update(board, undoActionName: "Add \(kind.displayName)")
        return panel
    }

    /// Pushes one set of Canvas credentials onto every Canvas panel, on every
    /// board.
    ///
    /// Grades, Assignments, and Canvas panels all authenticate against the
    /// same school with the same token, so entering it in one signs in all of
    /// them — and rotating it no longer leaves the others silently broken.
    /// The panel that supplied the credentials is excluded; it already has
    /// them, and its own edit is what is being saved.
    @discardableResult
    public func applyCanvasCredentials(host: String?, token: String?,
                                       excluding panelID: Panel.ID? = nil) -> Int {
        var pending: [(index: Int, board: Dashboard)] = []
        var updated = 0
        for (boardIndex, original) in dashboards.enumerated() {
            var board = original
            var changed = false
            for (panelIndex, panel) in board.panels.enumerated()
            where panel.kind.usesCanvasCredentials && panel.id != panelID {
                var connector = panel.settings.connector ?? ConnectorConfig()
                guard connector.projectURL != host || connector.token != token else { continue }
                connector.projectURL = host
                connector.token = token
                board.panels[panelIndex].settings.connector = connector
                changed = true
                updated += 1
            }
            guard changed else { continue }
            board.modifiedAt = Date()
            pending.append((boardIndex, board))
        }
        guard !pending.isEmpty else { return 0 }

        // One undo entry for the whole sweep — it was a single user action.
        recordUndo("Update Canvas Sign-In")
        for entry in pending {
            dashboards[entry.index] = entry.board
            didEdit(entry.board)
        }
        return updated
    }

    /// Pushes one Tessie API key onto every Tesla panel, on every board.
    ///
    /// One key covers a whole Tessie account, so a board built from a battery
    /// panel, a map panel and a security panel would otherwise need the same
    /// token pasted three times — and rotating it would break whichever ones
    /// were forgotten. The VIN is deliberately left alone: panels for two
    /// different cars share the key but not the car.
    @discardableResult
    public func applyTessieCredentials(apiKey: String?,
                                       excluding panelID: Panel.ID? = nil) -> Int {
        var pending: [(index: Int, board: Dashboard)] = []
        var updated = 0
        for (boardIndex, original) in dashboards.enumerated() {
            var board = original
            var changed = false
            for (panelIndex, panel) in board.panels.enumerated()
            where panel.kind.usesTessieCredentials && panel.id != panelID {
                var connector = panel.settings.connector ?? ConnectorConfig()
                guard connector.token != apiKey else { continue }
                connector.token = apiKey
                board.panels[panelIndex].settings.connector = connector
                changed = true
                updated += 1
            }
            guard changed else { continue }
            board.modifiedAt = Date()
            pending.append((boardIndex, board))
        }
        guard !pending.isEmpty else { return 0 }

        // One undo entry for the whole sweep — it was a single user action.
        recordUndo("Update Tessie API Key")
        for entry in pending {
            dashboards[entry.index] = entry.board
            didEdit(entry.board)
        }
        return updated
    }

    /// Pushes one Home Assistant address and token onto every Home Assistant
    /// panel, on every board.
    ///
    /// One server serves the whole house, so a board built from an upstairs
    /// temperature panel, a front-door panel and a thermostat would otherwise
    /// need the same long-lived token pasted three times — and rotating it
    /// would break whichever ones were forgotten. Same sweep, same single
    /// undo entry, as the Tessie key above.
    @discardableResult
    public func applyHomeAssistantCredentials(baseURL: String?, token: String?,
                                              excluding panelID: Panel.ID? = nil) -> Int {
        var pending: [(index: Int, board: Dashboard)] = []
        var updated = 0
        for (boardIndex, original) in dashboards.enumerated() {
            var board = original
            var changed = false
            for (panelIndex, panel) in board.panels.enumerated()
            where panel.kind == .homeAssistant && panel.id != panelID {
                var connector = panel.settings.connector ?? ConnectorConfig()
                guard connector.projectURL != baseURL || connector.token != token else { continue }
                connector.projectURL = baseURL
                connector.token = token
                board.panels[panelIndex].settings.connector = connector
                changed = true
                updated += 1
            }
            guard changed else { continue }
            board.modifiedAt = Date()
            pending.append((boardIndex, board))
        }
        guard !pending.isEmpty else { return 0 }

        recordUndo("Update Home Assistant Connection")
        for entry in pending {
            dashboards[entry.index] = entry.board
            didEdit(entry.board)
        }
        return updated
    }

    /// Copies a panel into the same board, placed in the first free slot.
    @discardableResult
    public func duplicatePanel(id: Panel.ID, in dashboardID: Dashboard.ID) -> Panel? {
        guard var board = dashboard(id: dashboardID),
              let original = board.panels.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.linkedContentID = nil
        copy.linkedContentModifiedAt = nil
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
        inserted.linkedContentID = nil
        inserted.linkedContentModifiedAt = nil
        inserted.frame = board.makeRoom(width: panel.frame.width,
                                        height: panel.frame.height)
        board.panels.append(inserted)
        update(board, undoActionName: "Paste \(panel.title)")
        return inserted
    }

    /// Places one panel on another dashboard while keeping its content linked.
    /// The destination gets an independent frame and per-device layouts, but a
    /// later configuration change from either placement updates them all.
    @discardableResult
    public func sharePanel(id panelID: Panel.ID, from sourceDashboardID: Dashboard.ID,
                           to targetDashboardID: Dashboard.ID) -> Panel? {
        guard sourceDashboardID != targetDashboardID,
              let sourceIndex = dashboards.firstIndex(where: { $0.id == sourceDashboardID }),
              let targetIndex = dashboards.firstIndex(where: { $0.id == targetDashboardID }),
              let panelIndex = dashboards[sourceIndex].panels.firstIndex(where: { $0.id == panelID })
        else { return nil }

        var source = dashboards[sourceIndex]
        var target = dashboards[targetIndex]
        var original = source.panels[panelIndex]
        let linkID = original.linkedContentID ?? UUID()

        if let existing = target.panels.first(where: { $0.linkedContentID == linkID }) {
            return existing
        }

        let now = Date()
        original.linkedContentID = linkID
        original.linkedContentModifiedAt = now
        source.panels[panelIndex] = original
        var placement = original
        placement.id = UUID()
        placement.frame = target.makeRoom(width: original.frame.width,
                                          height: original.frame.height)
        target.panels.append(placement)

        source.modifiedAt = now
        target.modifiedAt = now
        recordUndo("Share \(original.title)")
        dashboards[sourceIndex] = source
        dashboards[targetIndex] = target
        didEdit(source)
        didEdit(target)
        return placement
    }

    /// Makes one placement independent without removing any of the others.
    public func unlinkPanel(id panelID: Panel.ID, in dashboardID: Dashboard.ID) {
        guard var board = dashboard(id: dashboardID),
              let index = board.panels.firstIndex(where: { $0.id == panelID }),
              board.panels[index].linkedContentID != nil else { return }
        let title = board.panels[index].title
        board.panels[index].linkedContentID = nil
        board.panels[index].linkedContentModifiedAt = nil
        update(board, undoActionName: "Unlink \(title)")
    }

    public func linkedPlacementCount(for panel: Panel) -> Int {
        guard let linkID = panel.linkedContentID else { return 1 }
        return dashboards.reduce(0) { count, board in
            count + board.panels.count(where: { $0.linkedContentID == linkID })
        }
    }

    public func dashboardContainsSharedPanel(_ panel: Panel,
                                             dashboardID: Dashboard.ID) -> Bool {
        guard let linkID = panel.linkedContentID,
              let board = dashboard(id: dashboardID) else { return false }
        return board.panels.contains { $0.linkedContentID == linkID }
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
        rememberRemote(dashboard.id)
        if let index = dashboards.firstIndex(where: { $0.id == dashboard.id }) {
            guard dashboard.modifiedAt >= dashboards[index].modifiedAt else { return }
            dashboards[index] = dashboard
        } else {
            dashboards.append(dashboard)
        }
        // A display-only device starts with nothing on screen, so the first
        // board to arrive is the one to show.
        let selectionExists = selectedDashboardID.map { id in
            dashboards.contains { $0.id == id }
        } ?? false
        if !selectionExists {
            selectedDashboardID = dashboards.first?.id
        }
        reconcileLinkedPanels()
        scheduleSave()
    }

    /// CloudKit stores dashboards independently, so two records containing
    /// placements of one shared panel can arrive in either order. Reconcile
    /// them by the panel content revision and upload repaired authoring boards,
    /// giving every device eventual consistency without coupling their frames.
    private func reconcileLinkedPanels() {
        struct Revision {
            var panel: Panel
            var date: Date
        }

        var newest: [UUID: Revision] = [:]
        for board in dashboards {
            for panel in board.panels {
                guard let linkID = panel.linkedContentID else { continue }
                let revision = Revision(panel: panel,
                                        date: panel.linkedContentModifiedAt ?? board.modifiedAt)
                if let current = newest[linkID] {
                    let replaces = revision.date > current.date
                        || (revision.date == current.date
                            && revision.panel.id.uuidString > current.panel.id.uuidString)
                    if replaces { newest[linkID] = revision }
                } else {
                    newest[linkID] = revision
                }
            }
        }

        var changedBoards: [Dashboard] = []
        for boardIndex in dashboards.indices {
            var board = dashboards[boardIndex]
            var changed = false
            var latestApplied = board.modifiedAt
            for panelIndex in board.panels.indices {
                guard let linkID = board.panels[panelIndex].linkedContentID,
                      let revision = newest[linkID] else { continue }
                var placement = board.panels[panelIndex]
                if placement.kind != revision.panel.kind
                    || placement.title != revision.panel.title
                    || placement.settings != revision.panel.settings
                    || placement.linkedContentModifiedAt != revision.date {
                    placement.kind = revision.panel.kind
                    placement.title = revision.panel.title
                    placement.settings = revision.panel.settings
                    placement.linkedContentModifiedAt = revision.date
                    board.panels[panelIndex] = placement
                    changed = true
                    latestApplied = max(latestApplied, revision.date)
                }
            }
            guard changed else { continue }
            board.modifiedAt = latestApplied
            dashboards[boardIndex] = board
            changedBoards.append(board)
        }

        if authorsBoards {
            for board in changedBoards { onLocalSave?(board) }
        }
    }

    public func applyRemoteDeletion(id: Dashboard.ID) {
        dashboards.removeAll { $0.id == id }
        if remoteKnownIDs.remove(id) != nil {
            SBStorage.write(Array(remoteKnownIDs), to: remoteIDsURL)
        }
        if selectedDashboardID == id { selectedDashboardID = dashboards.first?.id }
        scheduleSave()
    }

    /// Applies the complete set of boards the Mac bridge just sent.
    ///
    /// Display-only devices only. A Mac, iPad or iPhone authors its own boards
    /// and syncs them through iCloud; letting a bridge on the network replace
    /// them would let one Mac quietly overwrite everybody's work.
    ///
    /// Whole-set semantics, so a board deleted on the Mac disappears here too —
    /// but only if the bridge is the thing that put it here. Anything iCloud
    /// delivered stays, because the Mac's list is not authoritative about
    /// boards made on an iPhone it hasn't seen.
    public func applyBridgeBoards(_ incoming: [Dashboard]) {
        guard !authorsBoards else {
            adoptBridgeBoards(incoming)
            return
        }

        for board in incoming {
            if let index = dashboards.firstIndex(where: { $0.id == board.id }) {
                guard board.modifiedAt >= dashboards[index].modifiedAt else { continue }
                guard board != dashboards[index] else { continue }
                dashboards[index] = board
            } else {
                dashboards.append(board)
            }
        }

        let incomingIDs = Set(incoming.map(\.id))
        let withdrawn = bridgeKnownIDs.subtracting(incomingIDs).subtracting(remoteKnownIDs)
        if !withdrawn.isEmpty {
            dashboards.removeAll { withdrawn.contains($0.id) }
        }
        if bridgeKnownIDs != incomingIDs {
            bridgeKnownIDs = incomingIDs
            SBStorage.write(Array(bridgeKnownIDs), to: bridgeIDsURL)
        }

        // Same rule as iCloud arrivals: a screen showing nothing should show
        // the first board that turns up.
        let selectionExists = selectedDashboardID.map { id in
            dashboards.contains { $0.id == id }
        } ?? false
        if !selectionExists {
            selectedDashboardID = dashboards.first?.id
        }
        scheduleSave()
    }

    /// Takes boards from the Mac bridge on a device that authors its own.
    ///
    /// iCloud is the proper channel between two devices that both make boards,
    /// and when it works this does nothing: the ids already match. It matters
    /// when iCloud *can't* work — the two ends signed into different CloudKit
    /// environments, a container whose schema was never deployed to production,
    /// an account not signed in yet — where a Mac sitting on the same Wi-Fi
    /// already has every board and the iPhone was showing the starter board
    /// with no way to reach them.
    ///
    /// Strictly additive, because a Mac on the network is not authoritative
    /// here. Boards this device made are never modified and never removed; the
    /// Mac's list not mentioning a board means nothing. Only boards adopted
    /// from the bridge can be updated by it, and only when the Mac's copy is
    /// genuinely newer.
    private func adoptBridgeBoards(_ incoming: [Dashboard]) {
        var adopted = false
        var changed = false

        for board in incoming {
            if let index = dashboards.firstIndex(where: { $0.id == board.id }) {
                // Ours, or iCloud's. Either way the bridge doesn't get to
                // rewrite it — only a board we took from the bridge in the
                // first place.
                guard bridgeAdoptedIDs.contains(board.id) else { continue }
                guard board.modifiedAt > dashboards[index].modifiedAt else { continue }
                guard board != dashboards[index] else { continue }
                dashboards[index] = board
                changed = true
            } else {
                // Already adopted but no longer present means the user deleted
                // it here. Re-adding it on the Mac's next broadcast would make
                // deletion impossible while the two are on the same network.
                guard !bridgeAdoptedIDs.contains(board.id) else { continue }
                dashboards.append(board)
                bridgeAdoptedIDs.insert(board.id)
                adopted = true
                changed = true
            }
        }

        if adopted {
            SBStorage.write(Array(bridgeAdoptedIDs), to: bridgeAdoptedIDsURL)
        }
        guard changed else { return }

        // A phone that had nothing but the starter board should land on a real
        // one rather than leave the user to go find it.
        let selectionExists = selectedDashboardID.map { id in
            dashboards.contains { $0.id == id }
        } ?? false
        if !selectionExists {
            selectedDashboardID = dashboards.first?.id
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func didEdit(_ dashboard: Dashboard) {
        scheduleSave()
        onLocalSave?(dashboard)
    }

    private func load() {
        remoteKnownIDs = Set(SBStorage.read([UUID].self, from: remoteIDsURL) ?? [])
        bridgeKnownIDs = Set(SBStorage.read([UUID].self, from: bridgeIDsURL) ?? [])
        bridgeAdoptedIDs = Set(SBStorage.read([UUID].self, from: bridgeAdoptedIDsURL) ?? [])
        var saved = SBStorage.read([Dashboard].self, from: fileURL) ?? []

        if !authorsBoards {
            // On a display-only device the local file is nothing but a cache of
            // what arrived from elsewhere, so anything neither iCloud nor the
            // bridge ever sent is a leftover — in practice the starter board an
            // older build made here, which is why the TV could sit on a board
            // that was on no other device. Dropped locally only: this never
            // deletes anything from iCloud or the Mac.
            saved = saved.filter {
                remoteKnownIDs.contains($0.id) || bridgeKnownIDs.contains($0.id)
            }
        }

        if saved.isEmpty && authorsBoards {
            saved = [.starter()]
        }
        dashboards = saved
        selectedDashboardID = dashboards.first?.id
    }

    private func rememberRemote(_ id: Dashboard.ID) {
        guard remoteKnownIDs.insert(id).inserted else { return }
        SBStorage.write(Array(remoteKnownIDs), to: remoteIDsURL)
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
