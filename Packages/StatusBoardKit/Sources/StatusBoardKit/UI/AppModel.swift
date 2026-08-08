import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif
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
    /// Whether a pair of smart glasses is on the other end of anything. Decides
    /// if the Smart Glasses screen appears in the menus at all.
    public let glassesLink = GlassesLink.shared

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
        self.sync = CloudSyncEngine(store: store, snapshots: snapshots)
        #if os(macOS)
        self.bridgeServer = BridgeServer()
        #endif

        // Mirrored board by board rather than through `allPanels`, so the
        // widget's edit screen can ask which board a panel comes from.
        snapshots.widgetPanelProvider = { [weak store] in
            (store?.dashboards ?? []).flatMap { board in
                board.panels.map {
                    WidgetPanelInfo(panelID: $0.id.uuidString, key: $0.snapshotKey,
                                    title: $0.title, kind: $0.kind, settings: $0.settings,
                                    boardID: board.id.uuidString, boardName: board.name,
                                    boardAppearance: board.appearance)
                }
            }
        }
        bridgeClient.identity = Self.thisDeviceIdentity()
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
        // Boards over the local network. A display takes the Mac's list whole;
        // a device that authors its own only ever adds from it, so an iPhone
        // that iCloud has failed still finds the boards on the Wi-Fi while its
        // own are left alone.
        bridgeClient.onBoards = { [weak store] boards in
            store?.applyBridgeBoards(boards)
        }
        #if os(macOS)
        bridgeServer.onSnapshot = { [weak snapshots] key, record in
            // `BridgeServer` already sent this push to subscribers. Store it
            // without asking the SnapshotStore observer to relay it again.
            snapshots?.setAll([key: record], notifyObserver: false)
        }
        bridgeServer.boardProvider = { [weak store] in
            (store?.dashboards ?? []).map { $0.redactedForExternalTransfer() }
        }
        bridgeServer.snapshotProvider = { [weak snapshots] in snapshots?.records ?? [:] }
        snapshots.recordObserver = { [weak bridgeServer] key, record in
            bridgeServer?.relaySnapshot(key: key, record: record)
        }
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

    /// How this copy of Status Board introduces itself to a Mac bridge. Stable
    /// across launches so a device that reconnects is recognised as itself
    /// rather than counted twice.
    private static func thisDeviceIdentity() -> BridgeClientIdentity {
        let key = "sb.bridge.clientID"
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: key) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: key)
            return fresh
        }()
        #if os(iOS)
        let name = UIDevice.current.name
        #elseif os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = SBDeviceClass.current.displayName
        #endif
        return BridgeClientIdentity(id: id, name: name,
                                    deviceClass: SBDeviceClass.current.rawValue,
                                    app: "Status Board")
    }

    public func start() {
        installK12Reauthenticator()
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

    /// Teaches the K12 session how to sign itself back in on this device.
    ///
    /// The portal's session lapses on its own schedule — a night is enough —
    /// and until this existed, every lapse ended at a sheet somebody had to
    /// open. Where WebKit exists, the cached portal sign-in is spent offscreen
    /// to mint a fresh session. On Apple TV there is no WebKit, so a lapsed
    /// session is handed to the Mac bridge instead: the panel's fetch asks the
    /// Mac for the finished schedule, and nothing here needs to recover at all.
    private func installK12Reauthenticator() {
        #if canImport(WebKit) && !os(tvOS) && !os(watchOS)
        K12Session.shared.reauthenticator = { portal in
            await K12SilentSignIn.shared.refresh(portal: portal)
        }
        #endif
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
