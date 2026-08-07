import Foundation

/// The Home Assistant address and access token, shared by every panel.
///
/// One server serves the whole house, so making each panel carry its own copy
/// would mean pasting the same long-lived token for the upstairs temperature
/// panel, the front door panel and the thermostat — and rotating it would
/// leave whichever ones you forgot silently broken. Same shape and same
/// reasoning as `TessieCredentials` and `CanvasCredentials`.
@MainActor
@Observable
public final class HomeAssistantCredentials {
    public static let shared = HomeAssistantCredentials()

    /// "http://homeassistant.local:8123" — scheme and port included, no path.
    public private(set) var baseURL: String?
    public private(set) var token: String?

    private static let keychainAccount = "homeassistant.credentials"

    private init() { load() }

    public var isConfigured: Bool { baseURL != nil && token != nil }

    /// A Sendable copy, for the data source — it fetches off the main actor.
    public struct Snapshot: Sendable, Hashable {
        public var baseURL: String?
        public var token: String?
    }

    public var snapshot: Snapshot { Snapshot(baseURL: baseURL, token: token) }

    /// Records what a panel was just saved with. Returns whether anything
    /// actually changed, so callers can skip the propagation sweep when a
    /// panel was merely re-saved untouched.
    @discardableResult
    public func adopt(baseURL rawURL: String?, token rawToken: String?) -> Bool {
        // Only ever promote real values: clearing a field in one panel is an
        // edit to that panel, not an instruction to sign every panel out.
        var didChange = false
        if let url = Self.normalizedURL(rawURL), url != baseURL {
            baseURL = url
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
        baseURL = nil
        token = nil
        KeychainBlobStore.delete(account: Self.keychainAccount)
    }

    /// Fills in whatever a connector is missing, leaving anything already set
    /// alone — how a newly created Home Assistant panel arrives already
    /// pointed at the right server.
    public func applyDefaults(to config: inout ConnectorConfig) {
        Self.fill(&config, from: snapshot)
    }

    /// The same defaulting, for the data source fetching off the main actor,
    /// so a panel that reached this device before the token did still works.
    nonisolated public static func resolved(_ config: ConnectorConfig?) async -> ConnectorConfig {
        var resolved = config ?? ConnectorConfig()
        fill(&resolved, from: await HomeAssistantCredentials.shared.snapshot)
        return resolved
    }

    nonisolated static func fill(_ config: inout ConnectorConfig, from shared: Snapshot) {
        if normalizedURL(config.projectURL) == nil { config.projectURL = shared.baseURL }
        if normalized(config.token) == nil { config.token = shared.token }
    }

    nonisolated static func normalized(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Accepts what people actually type. A bare host gets `http://`, because
    /// the common case is a box on the LAN with no certificate; a trailing
    /// slash or a pasted `/lovelace` path is trimmed back to the origin.
    nonisolated static func normalizedURL(_ raw: String?) -> String? {
        guard var text = normalized(raw) else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text), let host = components.host,
              !host.isEmpty else { return nil }
        var origin = "\(components.scheme ?? "http")://\(host)"
        if let port = components.port { origin += ":\(port)" }
        return origin
    }

    // MARK: - Persistence

    private func load() {
        guard let data = KeychainBlobStore.load(account: Self.keychainAccount),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        baseURL = Self.normalizedURL(raw["baseURL"])
        token = Self.normalized(raw["token"])
    }

    private func save() {
        var raw: [String: String] = [:]
        if let baseURL { raw["baseURL"] = baseURL }
        if let token { raw["token"] = token }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
    }
}
