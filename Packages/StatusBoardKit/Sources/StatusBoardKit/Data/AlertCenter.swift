import Foundation
#if canImport(UserNotifications) && !os(tvOS)
import UserNotifications
#endif

/// Posts a local notification when a panel's value crosses its configured
/// thresholds. One notification per direction per cooldown window, and one
/// when the value recovers.
@MainActor
public final class AlertCenter {
    public static let cooldown: TimeInterval = 15 * 60

    /// Panels currently in an alerting state, keyed by panel id + direction.
    private var lastFired: [String: Date] = [:]
    private var inAlert: Set<String> = []
    private var requestedAuthorization = false

    private let panelsProvider: () -> [Panel]

    public init(panelsProvider: @escaping () -> [Panel]) {
        self.panelsProvider = panelsProvider
    }

    public func evaluate(key: String, value: Double, now: Date = Date()) {
        for panel in panelsProvider() where panel.snapshotKey == key {
            check(panel: panel, value: value, now: now)
        }
    }

    private func check(panel: Panel, value: Double, now: Date) {
        let settings = panel.settings
        guard settings.alertAbove != nil || settings.alertBelow != nil else { return }

        var breached: (direction: String, limit: Double)?
        if let above = settings.alertAbove, value > above {
            breached = ("above", above)
        } else if let below = settings.alertBelow, value < below {
            breached = ("below", below)
        }

        let stateKey = panel.id.uuidString
        if let breached {
            let fireKey = stateKey + "." + breached.direction
            let wasAlerting = inAlert.contains(stateKey)
            inAlert.insert(stateKey)
            if let last = lastFired[fireKey], now.timeIntervalSince(last) < Self.cooldown {
                return
            }
            if wasAlerting && lastFired[fireKey] != nil { return }
            lastFired[fireKey] = now
            deliver(title: "\(panel.title) is \(breached.direction) \(compact(breached.limit))",
                    body: "Current value: \(compact(value))\(settings.unit.map { " \($0)" } ?? "")")
        } else if inAlert.remove(stateKey) != nil {
            deliver(title: "\(panel.title) recovered",
                    body: "Back to \(compact(value))\(settings.unit.map { " \($0)" } ?? "")")
        }
    }

    private func compact(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private func deliver(title: String, body: String) {
        #if canImport(UserNotifications) && !os(tvOS)
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                         content: content, trigger: nil))
        #endif
    }
}
