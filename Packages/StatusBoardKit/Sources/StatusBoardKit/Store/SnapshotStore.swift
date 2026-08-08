import Foundation
import Observation
#if canImport(WidgetKit) && !os(tvOS)
import WidgetKit
#endif

/// Panel metadata mirrored into the App Group so widgets can offer a picker.
public struct WidgetPanelInfo: Codable, Hashable, Sendable, Identifiable {
    /// The panel's own identity. This is what the widget's configuration
    /// stores, *not* `key`: two boards can push to the same bridge key, and a
    /// picker whose rows collide would silently hand the widget the wrong one.
    public var panelID: String
    public var id: String { panelID }
    public var key: String
    public var title: String
    public var kind: PanelKind
    /// The panel's own settings, so a widget renders it the way the board
    /// does — temperature units, which home mode a reading came from, how a
    /// chart is styled. Widgets have no access to `dashboards.json`.
    public var settings: PanelSettings
    /// The board this panel sits on, so the widget's edit screen can ask which
    /// board first and then which panel from it.
    public var boardID: String
    public var boardName: String
    /// Needed to resolve `.board` into the theme this placement actually uses.
    /// A linked panel can therefore follow each dashboard's theme independently,
    /// while a panel with an explicit theme stays visually fixed everywhere.
    public var boardAppearance: BoardAppearance

    public init(panelID: String, key: String, title: String, kind: PanelKind,
                settings: PanelSettings = PanelSettings(),
                boardID: String = "", boardName: String = "",
                boardAppearance: BoardAppearance = BoardAppearance()) {
        self.panelID = panelID
        self.key = key
        self.title = title
        self.kind = kind
        self.settings = settings
        self.boardID = boardID
        self.boardName = boardName
        self.boardAppearance = boardAppearance
    }

    /// Hand-written so a widget still draws from a state file an older build
    /// wrote. The file is a mirror rewritten every 30 seconds, but failing to
    /// decode it would blank every complication until then.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(PanelKind.self, forKey: .kind)
        settings = try container.decodeIfPresent(PanelSettings.self, forKey: .settings)
            ?? PanelSettings()
        // Before boards were mirrored, the key doubled as the identity — and
        // for every panel but a bridge one it still is the panel's UUID.
        panelID = try container.decodeIfPresent(String.self, forKey: .panelID) ?? key
        boardID = try container.decodeIfPresent(String.self, forKey: .boardID) ?? ""
        boardName = try container.decodeIfPresent(String.self, forKey: .boardName) ?? ""
        boardAppearance = try container.decodeIfPresent(BoardAppearance.self,
                                                        forKey: .boardAppearance)
            ?? BoardAppearance()
    }
}

/// A board offered in the widget's board picker.
public struct WidgetBoardInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The file widgets read from the shared App Group container.
public struct WidgetSharedState: Codable, Sendable {
    public var panels: [WidgetPanelInfo]
    public var records: [String: SnapshotRecord]

    public init(panels: [WidgetPanelInfo] = [], records: [String: SnapshotRecord] = [:]) {
        self.panels = panels
        self.records = records
    }

    public static var fileURL: URL {
        SBStorage.sharedContainerURL().appendingPathComponent("widget-state.json")
    }

    public static func load() -> WidgetSharedState {
        SBStorage.read(WidgetSharedState.self, from: fileURL) ?? WidgetSharedState()
    }

    /// The boards a widget can choose from, in board order. Derived from the
    /// panels rather than stored, so a board only shows up once it holds
    /// something a widget could actually display.
    public var boards: [WidgetBoardInfo] {
        var seen: Set<String> = []
        var result: [WidgetBoardInfo] = []
        for panel in panels where !panel.boardID.isEmpty {
            guard seen.insert(panel.boardID).inserted else { continue }
            result.append(WidgetBoardInfo(id: panel.boardID, name: panel.boardName))
        }
        return result
    }

    /// The panels on one board, or all of them when no board is chosen — and
    /// also when the chosen board is gone, since a widget still pointed at a
    /// deleted board should keep showing something rather than go blank.
    public func panels(onBoard boardID: String?) -> [WidgetPanelInfo] {
        guard let boardID, !boardID.isEmpty else { return panels }
        let scoped = panels.filter { $0.boardID == boardID }
        return scoped.isEmpty ? panels : scoped
    }

    /// Resolves a widget configuration to the panel it should draw.
    public func panel(id: String?, onBoard boardID: String?) -> WidgetPanelInfo? {
        let candidates = panels(onBoard: boardID)
        guard let id else { return candidates.first }
        return candidates.first { $0.panelID == id }
            // Widgets configured before boards were mirrored stored the
            // snapshot key instead of the panel's identity.
            ?? candidates.first { $0.key == id }
            ?? candidates.first
    }
}

/// Holds the latest data payload for every snapshot key (panel IDs and
/// bridge keys), caches them to disk, and mirrors them to widgets.
@MainActor
@Observable
public final class SnapshotStore {
    public private(set) var records: [String: SnapshotRecord] = [:]

    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored public var widgetPanelProvider: (() -> [WidgetPanelInfo])?
    /// Announces a newly stored local value. The Mac bridge uses this to relay
    /// fetched panels (Calendar included), not only values pushed to its HTTP
    /// endpoint. Callers ingesting a value that the bridge already broadcast
    /// can suppress it to avoid sending the same packet twice.
    @ObservationIgnored public var recordObserver: ((String, SnapshotRecord) -> Void)?
    /// Separate observer for private-iCloud portable values. Keeping this apart
    /// from the bridge observer lets an incoming CloudKit value be relayed on
    /// the LAN without immediately uploading itself again.
    @ObservationIgnored public var syncObserver: ((String, SnapshotRecord) -> Void)?
    /// Called with (key, latestNumericValue) whenever a snapshot carries a
    /// number — the alert engine hangs off this.
    @ObservationIgnored public var numericObserver: ((String, Double) -> Void)?

    public init() {
        cacheURL = SBStorage.localSupportURL().appendingPathComponent("snapshots.json")
        if let cached = SBStorage.read([String: SnapshotRecord].self, from: cacheURL) {
            records = cached
        }
    }

    public func record(for key: String) -> SnapshotRecord? {
        records[key]
    }

    public func set(_ snapshot: DataSnapshot, for key: String, at date: Date = Date()) {
        let record = SnapshotRecord(snapshot: snapshot, updatedAt: date)
        records[key] = record
        notifyNumeric(key: key, snapshot: snapshot)
        recordObserver?(key, record)
        syncObserver?(key, record)
        schedulePersist()
    }

    public func setAll(_ incoming: [String: SnapshotRecord], notifyObserver: Bool = true,
                       notifySyncObserver: Bool = true) {
        for (key, record) in incoming {
            if let existing = records[key], existing.updatedAt > record.updatedAt { continue }
            records[key] = record
            notifyNumeric(key: key, snapshot: record.snapshot)
            if notifyObserver { self.recordObserver?(key, record) }
            if notifySyncObserver { self.syncObserver?(key, record) }
        }
        schedulePersist()
    }

    private func notifyNumeric(key: String, snapshot: DataSnapshot) {
        guard let observer = numericObserver else { return }
        switch snapshot {
        case .number(let value, _):
            observer(key, value)
        case .series(let series):
            if let last = series.points.last { observer(key, last.value) }
        default:
            break
        }
    }

    public func clear(key: String) {
        records[key] = nil
        schedulePersist()
    }

    @ObservationIgnored private var lastWidgetSync = Date.distantPast
    @ObservationIgnored private var widgetSyncScheduled = false
    /// Minimum spacing between widget mirror writes + timeline reloads —
    /// bridge pushes can arrive every few seconds, and reloading widgets that
    /// often burns the system's reload budget.
    private static let widgetSyncInterval: TimeInterval = 30

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    public func persistNow() {
        SBStorage.write(records, to: cacheURL)
        let elapsed = Date().timeIntervalSince(lastWidgetSync)
        if elapsed >= Self.widgetSyncInterval {
            syncWidgetsNow()
        } else if !widgetSyncScheduled {
            // Trailing-edge sync so the last value in a burst still lands.
            widgetSyncScheduled = true
            let delay = Self.widgetSyncInterval - elapsed
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.widgetSyncScheduled = false
                self?.syncWidgetsNow()
            }
        }
    }

    private func syncWidgetsNow() {
        lastWidgetSync = Date()
        let panels = widgetPanelProvider?() ?? []
        var shared = WidgetSharedState(panels: panels)
        // Only mirror keys a widget could actually display.
        let wanted = Set(panels.map(\.key))
        shared.records = records.filter { wanted.contains($0.key) || $0.key.hasPrefix(BridgeKeys.prefix) }
        SBStorage.write(shared, to: WidgetSharedState.fileURL)
        #if canImport(WidgetKit) && !os(tvOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
