import Foundation

/// The Tessie API key, shared by every Tesla panel.
///
/// One key covers a whole Tessie account and every car on it, so making each
/// panel carry its own copy would mean pasting the same token for the battery
/// panel, the map panel and the security panel — and rotating it would leave
/// whichever ones you forgot silently broken. It lives here instead: the first
/// panel you fill in publishes it, later panels start with it already set, and
/// an update reaches all of them at once. Same shape as `CanvasCredentials`.
///
/// The most recently chosen VIN rides along, so adding a second panel for the
/// same car takes no typing.
@MainActor
@Observable
public final class TessieCredentials {
    public static let shared = TessieCredentials()

    public private(set) var apiKey: String?
    /// The VIN a panel was last pointed at. A convenience default only —
    /// each panel stores its own.
    public private(set) var defaultVIN: String?

    private static let keychainAccount = "tessie.credentials"

    private init() { load() }

    public var isConfigured: Bool { apiKey != nil }

    /// A Sendable copy, for the data source — it fetches off the main actor.
    public struct Snapshot: Sendable, Hashable {
        public var apiKey: String?
        public var defaultVIN: String?
    }

    public var snapshot: Snapshot { Snapshot(apiKey: apiKey, defaultVIN: defaultVIN) }

    /// Records what a panel was just saved with. Returns whether anything
    /// actually changed, so callers can skip the propagation sweep when a
    /// panel was merely re-saved untouched.
    @discardableResult
    public func adopt(apiKey rawKey: String?, vin rawVIN: String?) -> Bool {
        // Only ever promote real values: clearing a field in one panel is an
        // edit to that panel, not an instruction to sign every panel out.
        var didChange = false
        if let newKey = Self.normalized(rawKey), newKey != apiKey {
            apiKey = newKey
            didChange = true
        }
        if let newVIN = Self.normalized(rawVIN)?.uppercased(), newVIN != defaultVIN {
            defaultVIN = newVIN
            didChange = true
        }
        guard didChange else { return false }
        save()
        return true
    }

    public func clear() {
        apiKey = nil
        defaultVIN = nil
        KeychainBlobStore.delete(account: Self.keychainAccount)
    }

    /// Fills in whatever a connector is missing, leaving anything already set
    /// alone — how a newly created Tesla panel arrives already signed in.
    public func applyDefaults(to config: inout ConnectorConfig) {
        Self.fill(&config, from: snapshot)
    }

    /// The same defaulting, for the data source fetching off the main actor,
    /// so a panel that reached this device before the key did still works.
    nonisolated public static func resolved(_ config: ConnectorConfig?) async -> ConnectorConfig {
        var resolved = config ?? ConnectorConfig()
        fill(&resolved, from: await TessieCredentials.shared.snapshot)
        return resolved
    }

    nonisolated static func fill(_ config: inout ConnectorConfig, from shared: Snapshot) {
        if normalized(config.token) == nil { config.token = shared.apiKey }
        if normalized(config.query) == nil { config.query = shared.defaultVIN }
    }

    nonisolated static func normalized(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Persistence

    private func load() {
        guard let data = KeychainBlobStore.load(account: Self.keychainAccount),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        apiKey = Self.normalized(raw["apiKey"])
        defaultVIN = Self.normalized(raw["vin"])?.uppercased()
    }

    private func save() {
        var raw: [String: String] = [:]
        if let apiKey { raw["apiKey"] = apiKey }
        if let defaultVIN { raw["vin"] = defaultVIN }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
    }
}
