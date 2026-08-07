import Foundation

/// The Canvas / Instructure address and access token, shared by every Canvas
/// panel.
///
/// Grades, Assignments, and the generic Canvas panel all talk to the same
/// school with the same token. Giving each its own copy meant pasting the
/// token again for every panel you added, and rotating a token left the others
/// silently broken while one worked. So the credentials live here instead: the
/// first panel you fill in publishes them, every panel created afterwards
/// starts with them, and an update reaches all of them at once.
///
/// Stored in the Keychain rather than a plist because an access token is a
/// credential. Panels keep their own copy as well — that is what syncs to your
/// other devices through the private iCloud database.
@MainActor
@Observable
public final class CanvasCredentials {
    public static let shared = CanvasCredentials()

    /// The Canvas host, as typed — e.g. `learn2.k12.com`. Never empty; nil
    /// when unset.
    public private(set) var host: String?
    public private(set) var token: String?

    private static let keychainAccount = "canvas.credentials"

    private init() { load() }

    public var isConfigured: Bool { host != nil && token != nil }

    /// A Sendable copy, for the data sources — they fetch off the main actor.
    public struct Snapshot: Sendable, Hashable {
        public var host: String?
        public var token: String?
    }

    public var snapshot: Snapshot { Snapshot(host: host, token: token) }

    /// Records credentials entered in one panel so every other panel can use
    /// them. Returns whether this actually changed anything, so callers can
    /// skip the propagation pass when a panel was merely re-saved unchanged.
    @discardableResult
    public func adopt(host rawHost: String?, token rawToken: String?) -> Bool {
        // Only ever promote real values: clearing one field in one panel is an
        // edit to that panel, not an instruction to sign every panel out.
        var didChange = false
        if let newHost = Self.normalized(rawHost), newHost != host {
            host = newHost
            didChange = true
        }
        if let newToken = Self.normalized(rawToken), newToken != token {
            token = newToken
            didChange = true
        }
        guard didChange else { return false }
        save()
        return true
    }

    public func clear() {
        host = nil
        token = nil
        KeychainBlobStore.delete(account: Self.keychainAccount)
    }

    /// Fills in whatever a connector is missing, leaving anything already set
    /// alone — how a newly created Canvas panel arrives already signed in.
    public func applyDefaults(to config: inout ConnectorConfig) {
        Self.fill(&config, from: snapshot)
    }

    /// The same defaulting, for data sources fetching off the main actor. A
    /// panel that reached this device before the credentials did still works.
    nonisolated public static func resolved(_ config: ConnectorConfig?) async -> ConnectorConfig {
        var resolved = config ?? ConnectorConfig()
        fill(&resolved, from: await CanvasCredentials.shared.snapshot)
        return resolved
    }

    nonisolated static func fill(_ config: inout ConnectorConfig, from shared: Snapshot) {
        if normalized(config.projectURL) == nil { config.projectURL = shared.host }
        if normalized(config.token) == nil { config.token = shared.token }
    }

    nonisolated static func normalized(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    // MARK: - Persistence

    private func load() {
        guard let data = KeychainBlobStore.load(account: Self.keychainAccount),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        host = Self.normalized(raw["host"])
        token = Self.normalized(raw["token"])
    }

    private func save() {
        var raw: [String: String] = [:]
        if let host { raw["host"] = host }
        if let token { raw["token"] = token }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
    }
}
