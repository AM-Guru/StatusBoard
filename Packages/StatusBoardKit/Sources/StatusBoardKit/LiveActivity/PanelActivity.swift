#if os(iOS)
import Foundation
import ActivityKit

/// A numeric panel pinned to the Dynamic Island / Lock Screen.
public struct PanelActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var value: Double
        public var unit: String?
        public var updatedAt: Date

        public init(value: Double, unit: String?, updatedAt: Date = Date()) {
            self.value = value
            self.unit = unit
            self.updatedAt = updatedAt
        }

        public var formatted: String {
            let text = value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(format: "%.1f", value)
            return unit.map { "\(text) \($0)" } ?? text
        }
    }

    public var panelTitle: String
    public var snapshotKey: String
    public var symbolName: String
    public var accentHex: String?

    public init(panelTitle: String, snapshotKey: String,
                symbolName: String, accentHex: String?) {
        self.panelTitle = panelTitle
        self.snapshotKey = snapshotKey
        self.symbolName = symbolName
        self.accentHex = accentHex
    }
}

/// Starts, updates, and ends panel Live Activities. Updates flow in from the
/// SnapshotStore's numeric observer, so bridge pushes, fetches, and Shortcuts
/// pushes all animate the island.
@MainActor
public final class LiveActivityManager {
    public static let shared = LiveActivityManager()

    private var activities: [String: Activity<PanelActivityAttributes>] = [:]

    private init() {
        // Reattach to activities that survived an app relaunch.
        for activity in Activity<PanelActivityAttributes>.activities {
            activities[activity.attributes.snapshotKey] = activity
        }
    }

    public var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    public func isActive(key: String) -> Bool {
        activities[key] != nil
    }

    public func start(panel: Panel, value: Double?, unit: String?) throws {
        guard isSupported else {
            throw SBError.message("Live Activities are disabled in Settings")
        }
        stop(key: panel.snapshotKey)
        let attributes = PanelActivityAttributes(
            panelTitle: panel.title,
            snapshotKey: panel.snapshotKey,
            symbolName: panel.kind.symbolName,
            accentHex: panel.settings.accentColorHex)
        let state = PanelActivityAttributes.ContentState(
            value: value ?? 0, unit: unit ?? panel.settings.unit)
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil))
        activities[panel.snapshotKey] = activity
    }

    public func update(key: String, value: Double) {
        guard let activity = activities[key] else { return }
        let state = PanelActivityAttributes.ContentState(
            value: value,
            unit: activity.content.state.unit)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    public func stop(key: String) {
        guard let activity = activities.removeValue(forKey: key) else { return }
        Task {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
    }
}
#endif
