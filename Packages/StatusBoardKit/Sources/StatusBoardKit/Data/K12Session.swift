import Foundation
import Observation
#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import WebKit
#endif

/// A signed-in K12 / Stride portal session, used to call the OLS JSON API
/// **natively over `URLSession`** — no embedded web view doing the work.
///
/// The portal authenticates with a session cookie and offers no token, so a
/// web view is used exactly once, for the sign-in itself (the same pattern as
/// any OAuth sheet). The resulting cookies are copied into this session's own
/// cookie jar, persisted in the Keychain, and every subsequent request is a
/// plain `URLSession` call — fast, cheap, and usable from widgets and
/// background refreshes where a `WKWebView` would be a non-starter.
///
/// Portal sessions lapse — overnight is enough — so cookies alone are not a
/// sign-in that survives. When a call comes back rejected, the session asks its
/// `reauthenticator` for a fresh one and retries once. On iPhone and Mac that
/// is `K12SilentSignIn`, which re-establishes the session offscreen from the
/// cookies the portal left in WebKit's persistent store (and, if you asked it
/// to remember your sign-in, from the saved password). On Apple TV, where there
/// is no WebKit at all, it is the Mac bridge. Between them, the panel signs
/// itself back in without anyone opening a sheet.
@MainActor
@Observable
public final class K12Session {
    public static let shared = K12Session()

    /// Not actor-isolated: it's a constant every caller needs, including
    /// non-main-actor data sources.
    public nonisolated static let defaultPortal = "https://home.k12.com"

    public enum State: Equatable {
        case signedOut
        case signedIn
        /// Cookies exist but the portal rejected them.
        case expired
    }

    public private(set) var state: State = .signedOut

    /// The portal these cookies belong to, remembered so a session arriving
    /// from another device knows which host to present itself to.
    public private(set) var portal: String = K12Session.defaultPortal

    /// When this session was last minted or refreshed. It is the tiebreaker
    /// when a copy arrives from another device: newest wins.
    public private(set) var updatedAt: Date = .distantPast

    /// Cookies are held and sent by hand — see `SessionCookieJar` for why the
    /// obvious `HTTPCookieStorage()` cannot be used.
    @ObservationIgnored private var jar = SessionCookieJar()
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // We attach `Cookie:` ourselves, so URLSession must not manage cookies
        // — and must never fall back to the process-wide shared storage.
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private init() {
        loadCookies()
    }

    // MARK: - Cookie persistence

    /// Session cookies are credentials, so they live in the Keychain rather
    /// than a plist.
    private static let keychainAccount = "k12.session.cookies"

    private func loadCookies() {
        guard let data = KeychainBlobStore.load(account: Self.keychainAccount),
              let stored = Self.decodeStored(data) else { return }
        jar = stored.jar
        portal = stored.portal
        updatedAt = stored.updatedAt
        if !jar.isEmpty { state = .signedIn }
    }

    /// Reads a stored session blob.
    ///
    /// v2 is a dictionary carrying the portal and the mint date alongside the
    /// cookies; v1 was the bare cookie array. Both are read — an app update
    /// that stopped understanding the old shape would sign every existing
    /// install out, which is the exact problem this whole change is about.
    nonisolated static func decodeStored(_ data: Data)
        -> (jar: SessionCookieJar, portal: String, updatedAt: Date)? {
        guard let stored = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = stored as? [String: Any],
           let raw = object["cookies"] as? [[String: String]] {
            return (SessionCookieJar.restored(from: raw),
                    (object["portal"] as? String) ?? defaultPortal,
                    (object["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                        ?? .distantPast)
        }
        if let raw = stored as? [[String: String]] {
            return (SessionCookieJar.restored(from: raw), defaultPortal, .distantPast)
        }
        return nil
    }

    /// Writes the jar back to the Keychain. `minted` marks this as a session
    /// this device just established, which stamps a new date and offers it to
    /// the other devices; a session that *arrived* from elsewhere keeps the
    /// date it came with, so it never bounces back and forth.
    private func saveCookies(minted: Bool) {
        if minted { updatedAt = Date() }
        let object: [String: Any] = [
            "cookies": jar.persistable,
            "portal": portal,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
        if minted { broadcast() }
    }

    public func signOut() {
        jar.removeAll()
        KeychainBlobStore.delete(account: Self.keychainAccount)
        state = .signedOut
        updatedAt = Date()
        broadcast()
    }

    /// Cookie names and count — enough to tell "nothing was captured" from
    /// "captured, but the portal still said no". Values are never included.
    public var diagnosticSummary: String {
        jar.isEmpty
            ? "no session cookies were captured from the web view"
            : "\(jar.cookies.count) session cookie(s): \(jar.names.joined(separator: ", "))"
    }

    // MARK: - Carrying the session to other devices

    /// A session in transit — to the private iCloud database, or over the Mac
    /// bridge — so a device that cannot run a web view can still hold one.
    ///
    /// Cookies only. The portal password, when you choose to save one, stays in
    /// this device's Keychain and never travels.
    public struct SessionPayload: Codable, Sendable, Equatable {
        public var portal: String
        public var cookies: [[String: String]]
        public var updatedAt: Date

        public init(portal: String, cookies: [[String: String]], updatedAt: Date) {
            self.portal = portal
            self.cookies = cookies
            self.updatedAt = updatedAt
        }
    }

    /// This device's session, or nil when there is nothing to share.
    public var payload: SessionPayload? {
        guard !jar.isEmpty else { return nil }
        return SessionPayload(portal: portal, cookies: jar.persistable, updatedAt: updatedAt)
    }

    /// Takes on a session established elsewhere, if it is newer than this one.
    ///
    /// Returns whether it was adopted, so a caller can tell "an Apple TV just
    /// got its first session" from "iCloud handed back what we already had".
    @discardableResult
    public func adopt(_ payload: SessionPayload) -> Bool {
        guard payload.updatedAt > updatedAt else { return false }
        let incoming = SessionCookieJar.restored(from: payload.cookies)
        // Every cookie expired in transit: nothing worth taking, but the date
        // still moves so we don't re-examine this payload forever.
        guard !incoming.isEmpty else {
            updatedAt = payload.updatedAt
            return false
        }
        jar = incoming
        portal = payload.portal
        state = .signedIn
        updatedAt = payload.updatedAt
        saveCookies(minted: false)
        return true
    }

    /// Signs out because another device did. Distinct from `signOut()` in that
    /// it doesn't tell everyone again.
    public func adoptRemoteSignOut() {
        guard !jar.isEmpty else { return }
        jar.removeAll()
        KeychainBlobStore.delete(account: Self.keychainAccount)
        state = .signedOut
        updatedAt = Date()
    }

    /// Called whenever this device mints, refreshes, or drops a session. The
    /// payload is nil for a sign-out. Sync and the bridge both listen.
    @ObservationIgnored private var changeHandlers: [(SessionPayload?) -> Void] = []

    public func onChange(_ handler: @escaping (SessionPayload?) -> Void) {
        changeHandlers.append(handler)
    }

    private func broadcast() {
        let payload = payload
        for handler in changeHandlers { handler(payload) }
    }

    // MARK: - Adopting a signed-in web session

    #if canImport(WebKit) && !os(tvOS) && !os(watchOS)
    /// Copies cookies out of a web view that has completed sign-in.
    ///
    /// Scoped to the portal's own registrable domain rather than a hardcoded
    /// `k12.com`, so a school on its own Canvas host works too — and so the
    /// rest of the browser's cookies are left where they are.
    @discardableResult
    public func adoptCookies(from dataStore: WKWebsiteDataStore,
                             portal: String = K12Session.defaultPortal) async -> Int {
        let scope = SessionCookieJar.registrableDomain(of: portal)
        let relevant = await dataStore.httpCookieStore.allCookies().filter {
            SessionCookieJar.domainMatches(host: scope, cookieDomain: $0.domain)
                || SessionCookieJar.domainMatches(host: $0.domain, cookieDomain: scope)
        }
        jar.absorb(relevant)
        guard !jar.isEmpty else { return 0 }
        self.portal = portal
        state = .signedIn
        saveCookies(minted: true)
        return relevant.count
    }
    #endif

    // MARK: - Silent re-authentication

    /// Establishes a fresh session without the user present. Set at launch by
    /// the composition root: an offscreen web view where WebKit exists, the Mac
    /// bridge on Apple TV. Returns whether a usable session was obtained.
    public typealias Reauthenticator = @MainActor (_ portal: String) async -> Bool

    @ObservationIgnored public var reauthenticator: Reauthenticator?

    /// How long to wait before trying again after a failed attempt. Panels
    /// refresh on their own timers — without this, a portal that is down (or a
    /// password that has changed) would be hammered once per panel per minute.
    private static let recoveryBackoff: TimeInterval = 120

    @ObservationIgnored private var recoveryTask: Task<Bool, Never>?
    @ObservationIgnored private var nextRecoveryAllowed: Date = .distantPast

    /// When a re-authentication last succeeded, for the settings screen.
    public private(set) var lastRecovery: Date?

    /// Runs the reauthenticator, at most one at a time. Concurrent panels all
    /// wait on the same attempt rather than starting a stampede of sign-ins.
    ///
    /// `force` is the user pressing a button, which ignores the backoff.
    @discardableResult
    public func recoverSession(portal: String? = nil, force: Bool = false) async -> Bool {
        if let recoveryTask { return await recoveryTask.value }
        guard let reauthenticator else { return false }
        if !force, Date() < nextRecoveryAllowed { return false }
        let target = portal ?? self.portal
        let task = Task { @MainActor in await reauthenticator(target) }
        recoveryTask = task
        let succeeded = await task.value
        recoveryTask = nil
        if succeeded {
            lastRecovery = Date()
            nextRecoveryAllowed = .distantPast
        } else {
            nextRecoveryAllowed = Date().addingTimeInterval(Self.recoveryBackoff)
        }
        return succeeded
    }

    /// Whether anything on this device can sign back in on its own — what the
    /// settings screen needs to decide between "Expired" and "Reconnecting…".
    public var canRecover: Bool { reauthenticator != nil }

    // MARK: - Native requests

    public var isSignedIn: Bool { state == .signedIn }

    /// Why a request could not be made, separately from why it failed. These
    /// are the two cases a silent re-authentication can fix.
    enum SessionFailure: LocalizedError {
        case signedOut
        case rejected

        var errorDescription: String? { message }

        var message: String {
            switch self {
            case .signedOut:
                return "Sign in to K12 in this panel's settings to load your schedule"
            case .rejected:
                return "Your K12 sign-in expired — sign in again in this panel's settings"
            }
        }
    }

    /// Performs an OLS API call, re-establishing the session and retrying once
    /// when the portal turns it down.
    public func json(path: String, portal: String = K12Session.defaultPortal) async throws -> JSONValue {
        do {
            return try await request(path: path, portal: portal)
        } catch let failure as SessionFailure {
            guard await recoverSession(portal: portal) else {
                throw SBError.message(failure.message)
            }
            do {
                return try await request(path: path, portal: portal)
            } catch let failure as SessionFailure {
                throw SBError.message(failure.message)
            }
        }
    }

    /// One request, with no recovery attached.
    ///
    /// The reauthenticators call this — never `json` — to check their work. A
    /// verification that could itself trigger a recovery would be waiting on
    /// the very task it is running inside.
    @discardableResult
    func request(path: String, portal: String) async throws -> JSONValue {
        var base = portal.trimmingCharacters(in: .whitespaces)
        if !base.contains("://") { base = "https://" + base }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw SBError.message("Invalid K12 portal URL")
        }
        guard state != .signedOut else { throw SessionFailure.signedOut }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(base, forHTTPHeaderField: "Referer")
        if let cookieHeader = jar.header(for: url) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            // Keep any refreshed session cookie the call handed back.
            if let fields = http.allHeaderFields as? [String: String], let final = http.url,
               jar.absorb(HTTPCookie.cookies(withResponseHeaderFields: fields, for: final)) {
                saveCookies(minted: true)
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if http.statusCode == 401 || http.statusCode == 403 {
                state = .expired
                throw SessionFailure.rejected
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SBError.message("K12 portal HTTP \(http.statusCode) for \(path)")
            }
            // A lapsed session is answered with the login page. A mistyped or
            // wrong-host path is answered with an HTML 404 — reporting that as
            // an expired sign-in sent people back to re-authenticate over and
            // over against a portal that had never rejected them.
            if contentType.contains("text/html") {
                state = .expired
                throw SessionFailure.rejected
            }
            // The portal answered us, so whatever we thought about this session
            // being stale was wrong. Without this the settings screen kept
            // reading "Expired" long after a silent refresh had fixed it.
            state = .signedIn
            self.portal = portal
        }
        return try JSONValue.parse(data)
    }

    /// Checks a session against the portal, quietly, returning nil when the
    /// portal accepted it and the reason when it didn't. Used by the sign-in
    /// sheet and by every reauthenticator to confirm the cookies they just
    /// captured actually work before reporting success.
    ///
    /// Only the *first* probe's failure is reported. Reporting the last one
    /// used to surface an HTML 404 from a path that never applied to this
    /// portal, dressed up as an expired session.
    func verify(portal: String) async -> Error? {
        var firstError: Error?
        for path in Self.probePaths(for: portal) {
            do {
                _ = try await request(path: path, portal: portal)
                return nil
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        return firstError ?? SBError.message("no response")
    }

    /// OLS and Canvas answer on different paths, and one portal setting serves
    /// both. The first probe is the one that suits this host; the rest are
    /// fallbacks.
    nonisolated static func probePaths(for portal: String) -> [String] {
        let host = (portal.contains("://") ? URL(string: portal)?.host : portal)?.lowercased()
            ?? portal.lowercased()
        let isCanvas = host.contains("instructure.com") || host.hasPrefix("learn")
        return isCanvas
            ? ["/api/v1/users/self", "/api/canvas/events/classes"]
            : ["/api/canvas/events/classes", "/api/v1/users/self"]
    }
}

// MARK: - Keychain blob helper

/// Stores an opaque blob (here: session cookies) in the Keychain.
enum KeychainBlobStore {
    private static let service = "guru.am.statusboard.session"

    static func save(_ data: Data, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

import Security
