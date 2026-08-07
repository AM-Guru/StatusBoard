import Foundation
import Observation
import SwiftUI
#if canImport(CoreSpotlight) && !os(tvOS)
import CoreSpotlight
#endif

/// Composition root shared by every app target.
@MainActor
@Observable
public final class AppModel {
    public let store: DashboardStore
    public let snapshots: SnapshotStore
    public let engine: DataSourceEngine
    public let bridgeClient: BridgeClient
    public let sync: CloudSyncEngine
    #if os(macOS)
    public let bridgeServer: BridgeServer
    #endif

    public var isEditing = false
    /// Which screen's arrangement the window is showing and editing. `nil` — the
    /// normal case — means this device's own live board. Setting it turns the
    /// whole detail area into that screen's layout editor, which is why it lives
    /// here rather than inside a sheet: arranging an Apple TV board deserves the
    /// full window, not a panel-sized modal.
    public var layoutTarget: SBDeviceClass?
    /// Whether the layout editor shows its options column beside the screen.
    public var showsLayoutInspector = true
    public var inspectedPanelID: Panel.ID?
    /// The panel keyboard commands act on (⌘D duplicate, ⌘C copy, delete).
    public var selectedPanelID: Panel.ID?

    @ObservationIgnored private var alertCenter: AlertCenter?

    public init() {
        let store = DashboardStore()
        let snapshots = SnapshotStore()
        self.store = store
        self.snapshots = snapshots
        self.engine = DataSourceEngine(snapshots: snapshots)
        self.bridgeClient = BridgeClient()
        self.sync = CloudSyncEngine(store: store)
        #if os(macOS)
        self.bridgeServer = BridgeServer()
        #endif

        snapshots.widgetPanelProvider = { [weak store] in
            (store?.allPanels ?? []).map {
                WidgetPanelInfo(key: $0.snapshotKey, title: $0.title, kind: $0.kind,
                                settings: $0.settings)
            }
        }
        bridgeClient.onSnapshot = { [weak snapshots] key, record in
            snapshots?.setAll([key: record])
        }
        bridgeClient.onConnect = { [weak self] in
            guard let self else { return }
            // Web clips (and anything that errored waiting for the bridge)
            // should retry immediately once the Mac is reachable.
            for panel in self.store.allPanels where panel.kind == .webClip {
                self.engine.refreshNow(panel: panel)
            }
        }
        // Boards over the local network, for the displays that can't author
        // their own. The store ignores this on any device that can, so an iPad
        // joining the bridge for panel data never has its boards replaced.
        bridgeClient.onBoards = { [weak store] boards in
            store?.applyBridgeBoards(boards)
        }
        #if os(macOS)
        bridgeServer.onSnapshot = { [weak snapshots] key, record in
            snapshots?.setAll([key: record])
        }
        bridgeServer.boardProvider = { [weak store] in store?.dashboards ?? [] }
        #endif
        engine.bridgeClient = bridgeClient

        let alerts = AlertCenter { [weak store] in store?.allPanels ?? [] }
        alertCenter = alerts
        snapshots.numericObserver = { [weak alerts] key, value in
            alerts?.evaluate(key: key, value: value)
            #if os(iOS)
            LiveActivityManager.shared.update(key: key, value: value)
            #endif
        }
    }

    public func start() {
        sync.start()
        // Apple TV and the Watch have no way to ask for boards themselves —
        // there's no "pull to refresh" on a wall display — so they poll.
        if !store.authorsBoards {
            sync.startAutomaticRefresh()
        }
        bridgeClient.startBrowsing()
        #if os(macOS)
        bridgeServer.start()
        #endif
        engine.rebuild(panels: store.allPanels)
        scheduleSpotlightIndex()
        observeDashboards()

        // Ingest values pushed by Shortcuts while the app wasn't running,
        // then keep draining while alive.
        IntentDataBridge.model = self
        IntentDataBridge.drainSpool(into: self)
        IntentDataBridge.applyFocusDashboard(to: self)
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                IntentDataBridge.drainSpool(into: self)
                IntentDataBridge.applyFocusDashboard(to: self)
            }
        }
    }

    /// Re-runs the fetch engine whenever any dashboard content changes
    /// (local edits or iCloud arrivals).
    private func observeDashboards() {
        withObservationTracking {
            _ = store.dashboards
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.engine.rebuild(panels: self.store.allPanels)
                self.scheduleSpotlightIndex()
                #if os(macOS)
                // Displays subscribed to this Mac follow board edits live.
                self.bridgeServer.publishBoards()
                #endif
                self.observeDashboards()
            }
        }
    }

    /// Re-indexes Spotlight, coalesced so rapid edits don't thrash the index.
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?

    func scheduleSpotlightIndex() {
        spotlightTask?.cancel()
        spotlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            SpotlightIndexer.index(dashboards: self.store.dashboards,
                                   records: self.snapshots.records)
        }
    }

    /// Opens the board referenced by a Spotlight result or a Handoff activity.
    public func handleActivity(_ activity: NSUserActivity) {
        var identifier: String?
        if activity.activityType == SpotlightIndexer.activityType {
            identifier = activity.userInfo?[SpotlightIndexer.boardIDKey] as? String
        }
        #if canImport(CoreSpotlight) && !os(tvOS)
        if identifier == nil, activity.activityType == CSSearchableItemActionType {
            identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        }
        #endif
        guard let identifier,
              let boardID = SpotlightIndexer.boardID(fromIdentifier: identifier)
                ?? UUID(uuidString: identifier),
              store.dashboard(id: boardID) != nil else { return }
        store.selectedDashboardID = boardID
    }

    /// Describes the visible board for Handoff to another device.
    public func currentActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: SpotlightIndexer.activityType)
        if let board = store.selectedDashboard {
            activity.title = board.name
            activity.userInfo = [SpotlightIndexer.boardIDKey: board.id.uuidString]
        }
        activity.isEligibleForHandoff = true
        return activity
    }

    /// The panel commands act on: the explicit selection, else the only panel
    /// on the board if there's exactly one.
    public func commandTargetPanel() -> (panel: Panel, dashboardID: Dashboard.ID)? {
        guard let board = store.selectedDashboard else { return nil }
        if let id = selectedPanelID,
           let panel = board.panels.first(where: { $0.id == id }) {
            return (panel, board.id)
        }
        if board.panels.count == 1, let only = board.panels.first {
            return (only, board.id)
        }
        return nil
    }

    /// Force-refreshes every fetched panel on the visible board.
    public func refreshVisibleBoard() {
        guard let board = store.selectedDashboard else { return }
        for panel in board.panels where panel.kind.isFetched {
            engine.refreshNow(panel: panel)
        }
    }

    public func inspectedPanel() -> (panel: Panel, dashboardID: Dashboard.ID)? {
        guard let id = inspectedPanelID else { return nil }
        for dashboard in store.dashboards {
            if let panel = dashboard.panels.first(where: { $0.id == id }) {
                return (panel, dashboard.id)
            }
        }
        return nil
    }
}
