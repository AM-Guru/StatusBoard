import Foundation
import Observation
#if canImport(WidgetKit) && !os(tvOS)
import WidgetKit
#endif

/// Panel metadata mirrored into the App Group so widgets can offer a picker.
public struct WidgetPanelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var kind: PanelKind
    /// The panel's own settings, so a widget renders it the way the board
    /// does — temperature units, which home mode a reading came from, how a
    /// chart is styled. Widgets have no access to `dashboards.json`.
    public var settings: PanelSettings

    public init(key: String, title: String, kind: PanelKind,
                settings: PanelSettings = PanelSettings()) {
        self.key = key
        self.title = title
        self.kind = kind
        self.settings = settings
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
        records[key] = SnapshotRecord(snapshot: snapshot, updatedAt: date)
        notifyNumeric(key: key, snapshot: snapshot)
        schedulePersist()
    }

    public func setAll(_ incoming: [String: SnapshotRecord]) {
        for (key, record) in incoming {
            if let existing = records[key], existing.updatedAt > record.updatedAt { continue }
            records[key] = record
            notifyNumeric(key: key, snapshot: record.snapshot)
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
