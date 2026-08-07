import Foundation
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
@MainActor
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

    /// Cookies are held and sent by hand — see `SessionCookieJar` for why the
    /// obvious `HTTPCookieStorage()` cannot be used.
    private var jar = SessionCookieJar()
    private lazy var session: URLSession = {
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
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return
        }
        jar = SessionCookieJar.restored(from: raw)
        if !jar.isEmpty { state = .signedIn }
    }

    private func saveCookies() {
        guard let data = try? JSONSerialization.data(withJSONObject: jar.persistable) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
    }

    public func signOut() {
        jar.removeAll()
        KeychainBlobStore.delete(account: Self.keychainAccount)
        state = .signedOut
    }

    /// Cookie names and count — enough to tell "nothing was captured" from
    /// "captured, but the portal still said no". Values are never included.
    public var diagnosticSummary: String {
        jar.isEmpty
            ? "no session cookies were captured from the web view"
            : "\(jar.cookies.count) session cookie(s): \(jar.names.joined(separator: ", "))"
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
        saveCookies()
        state = .signedIn
        return relevant.count
    }
    #endif

    // MARK: - Native requests

    public var isSignedIn: Bool { state == .signedIn }

    /// Performs an OLS API call. Throws a clear, actionable error when the
    /// session has lapsed — the portal answers those with `401` and a JSON
    /// body, so the status code is the signal, not the content type.
    public func json(path: String, portal: String = K12Session.defaultPortal) async throws -> JSONValue {
        var base = portal.trimmingCharacters(in: .whitespaces)
        if !base.contains("://") { base = "https://" + base }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw SBError.message("Invalid K12 portal URL")
        }
        guard state != .signedOut else {
            throw SBError.message("Sign in to K12 in this panel's settings to load your schedule")
        }

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
                saveCookies()
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if http.statusCode == 401 || http.statusCode == 403 {
                state = .expired
                throw SBError.message("Your K12 sign-in expired — sign in again in this panel's settings")
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
                throw SBError.message("Your K12 sign-in expired — sign in again in this panel's settings")
            }
        }
        return try JSONValue.parse(data)
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
