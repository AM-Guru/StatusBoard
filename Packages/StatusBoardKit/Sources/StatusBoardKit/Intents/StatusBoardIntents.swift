import Foundation
import AppIntents

/// Exposes the package's App Intents to app targets (which declare their own
/// AppIntentsPackage including this one).
public struct StatusBoardKitIntents: AppIntentsPackage {}

// MARK: - Push Value

/// Shortcuts action: push a number or text onto a Status Board key — the same
/// keys the Mac bridge uses, so graphs/progress/bridge panels pick it up.
/// Works on-device with no bridge required.
public struct PushValueIntent: AppIntent {
    public static let title: LocalizedStringResource = "Push Value to Status Board"
    public static let description = IntentDescription(
        "Sends a number or text to a Status Board key. Graph panels chart numeric history automatically.",
        categoryName: "Data")

    @Parameter(title: "Key", description: "e.g. steps, focus, commute")
    public var key: String

    @Parameter(title: "Number")
    public var number: Double?

    @Parameter(title: "Text")
    public var text: String?

    @Parameter(title: "Unit", description: "Shown next to numbers, e.g. %, km")
    public var unit: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("Push \(\.$number) \(\.$text) to \(\.$key)") {
            \.$unit
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else {
            throw SBError.message("A key is required")
        }
        guard number != nil || text != nil else {
            throw SBError.message("Provide a number or text to push")
        }
        IntentDataBridge.push(key: trimmedKey, number: number, text: text, unit: unit)
        let value = number.map { String($0) } ?? text ?? ""
        return .result(dialog: "Pushed \(value) to \(trimmedKey)")
    }
}

// MARK: - Get Panel Value

/// Shortcuts action: read the latest value of a panel or bridge key, for use
/// in automations ("If CPU above 90 → …").
public struct GetPanelValueIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Status Board Value"
    public static let description = IntentDescription(
        "Returns the latest value for a Status Board key or panel title.",
        categoryName: "Data")

    @Parameter(title: "Key or Panel Title")
    public var key: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Get the value of \(\.$key)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let value = IntentDataBridge.lookup(key: key) else {
            throw SBError.message("No data for “\(key)” yet")
        }
        return .result(value: value, dialog: "\(key): \(value)")
    }
}

// MARK: - Focus filter

#if !os(tvOS)
/// Ties a dashboard to a Focus mode: "When Work Focus is on, show the Ops
/// board." Configured in Settings → Focus → Focus Filters.
public struct DashboardFocusFilter: SetFocusFilterIntent {
    public static let title: LocalizedStringResource = "Set Dashboard"
    public static let description = IntentDescription(
        "Choose which dashboard Status Board shows while this Focus is on.")

    @Parameter(title: "Dashboard Name")
    public var dashboardName: String?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Dashboard",
                              subtitle: "\(dashboardName ?? "Unchanged")")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentDataBridge.setFocusDashboard(dashboardName)
        return .result()
    }
}
#endif

// MARK: - Data bridge

/// Connects intents to the running app when there is one, and to a spool file
/// in the shared container otherwise (drained on next launch/foreground).
@MainActor
public enum IntentDataBridge {
    public weak static var model: AppModel?

    struct SpoolEntry: Codable {
        var key: String
        var number: Double?
        var text: String?
        var unit: String?
        var at: Date
    }

    static var spoolURL: URL {
        SBStorage.sharedContainerURL().appendingPathComponent("intent-spool.jsonl")
    }

    public static func push(key: String, number: Double?, text: String?, unit: String?) {
        if let model {
            apply(SpoolEntry(key: key, number: number, text: text, unit: unit, at: Date()),
                  to: model)
            return
        }
        // No live app model (background intent launch) — spool for later and
        // surface immediately to widgets.
        let entry = SpoolEntry(key: key, number: number, text: text, unit: unit, at: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if var data = try? encoder.encode(entry) {
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: spoolURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: spoolURL)
            }
        }
        mirrorToWidgets(entry)
    }

    public static func lookup(key: String) -> String? {
        let normalized = key.trimmingCharacters(in: .whitespaces)
        let record: SnapshotRecord?
        if let model {
            record = model.snapshots.record(for: BridgeKeys.prefixed(normalized))
                ?? model.store.allPanels.first {
                    $0.title.localizedCaseInsensitiveCompare(normalized) == .orderedSame
                }.flatMap { model.snapshots.record(for: $0.snapshotKey) }
        } else {
            let shared = WidgetSharedState.load()
            record = shared.records[BridgeKeys.prefixed(normalized)]
                ?? shared.panels.first {
                    $0.title.localizedCaseInsensitiveCompare(normalized) == .orderedSame
                }.flatMap { shared.records[$0.key] }
        }
        switch record?.snapshot {
        case .number(let value, let unit):
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            return unit.map { "\(text) \($0)" } ?? text
        case .text(let text):
            return text
        case .series(let series):
            return series.points.last.map { String(format: "%.2f", $0.value) }
        case .statuses(let statuses):
            let down = statuses.filter { $0.state == .down }.count
            return down == 0 ? "all up" : "\(down) down"
        default:
            return nil
        }
    }

    // MARK: Focus

    static let focusDefaultsKey = "sb.focusDashboardName"

    /// Called by the Focus filter when a Focus turns on/off.
    public static func setFocusDashboard(_ name: String?) {
        let defaults = UserDefaults(suiteName: SBIdentifiers.appGroup) ?? .standard
        defaults.set(name, forKey: focusDefaultsKey)
        if let model { applyFocusDashboard(to: model) }
    }

    /// Switches the visible dashboard to the Focus-selected one, if any.
    public static func applyFocusDashboard(to model: AppModel) {
        let defaults = UserDefaults(suiteName: SBIdentifiers.appGroup) ?? .standard
        guard let name = defaults.string(forKey: focusDefaultsKey), !name.isEmpty,
              let board = model.store.dashboards.first(where: {
                  $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
              }) else { return }
        if model.store.selectedDashboardID != board.id {
            model.store.selectedDashboardID = board.id
        }
    }

    /// Applies spooled pushes into the live app (called at launch and
    /// periodically while running).
    public static func drainSpool(into model: AppModel) {
        guard let data = try? Data(contentsOf: spoolURL), !data.isEmpty else { return }
        try? FileManager.default.removeItem(at: spoolURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let entry = try? decoder.decode(SpoolEntry.self, from: line) {
                apply(entry, to: model)
            }
        }
    }

    private static func apply(_ entry: SpoolEntry, to model: AppModel) {
        let key = BridgeKeys.prefixed(entry.key)
        if let number = entry.number {
            model.snapshots.set(.number(number, unit: entry.unit), for: key, at: entry.at)
            // Maintain a chartable rolling history, like the bridge does.
            var points: [SeriesPoint] = []
            let historyKey = key + ".history"
            if case .series(let existing)? = model.snapshots.record(for: historyKey)?.snapshot {
                points = existing.points
            }
            points.append(SeriesPoint(date: entry.at, value: number))
            if points.count > 200 { points.removeFirst(points.count - 200) }
            model.snapshots.set(.series(SeriesData(points: points, unit: entry.unit)),
                                for: historyKey, at: entry.at)
        } else if let text = entry.text {
            model.snapshots.set(.text(text), for: key, at: entry.at)
        }
    }

    /// Background pushes still show up on widgets immediately.
    private static func mirrorToWidgets(_ entry: SpoolEntry) {
        var shared = WidgetSharedState.load()
        let key = BridgeKeys.prefixed(entry.key)
        if let number = entry.number {
            shared.records[key] = SnapshotRecord(snapshot: .number(number, unit: entry.unit),
                                                 updatedAt: entry.at)
        } else if let text = entry.text {
            shared.records[key] = SnapshotRecord(snapshot: .text(text), updatedAt: entry.at)
        }
        SBStorage.write(shared, to: WidgetSharedState.fileURL)
        #if canImport(WidgetKit) && !os(tvOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

#if canImport(WidgetKit) && !os(tvOS)
import WidgetKit
#endif
