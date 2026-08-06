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

    private let storage = HTTPCookieStorage()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
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
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        var restored = 0
        for entry in raw {
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in entry {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            if let cookie = HTTPCookie(properties: properties) {
                storage.setCookie(cookie)
                restored += 1
            }
        }
        if restored > 0 { state = .signedIn }
    }

    private func saveCookies() {
        let cookies = storage.cookies ?? []
        let raw: [[String: Any]] = cookies.compactMap { cookie in
            guard let properties = cookie.properties else { return nil }
            var entry: [String: Any] = [:]
            for (key, value) in properties {
                // Dates and strings survive JSON; anything else is derivable.
                if let date = value as? Date {
                    entry[key.rawValue] = ISO8601DateFormatter().string(from: date)
                } else if JSONSerialization.isValidJSONObject([value]) {
                    entry[key.rawValue] = value
                } else {
                    entry[key.rawValue] = String(describing: value)
                }
            }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
    }

    public func signOut() {
        for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
        KeychainBlobStore.delete(account: Self.keychainAccount)
        state = .signedOut
    }

    // MARK: - Adopting a signed-in web session

    #if canImport(WebKit) && !os(tvOS) && !os(watchOS)
    /// Copies cookies out of a web view that has completed sign-in.
    public func adoptCookies(from dataStore: WKWebsiteDataStore) async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        var adopted = 0
        for cookie in cookies where cookie.domain.contains("k12.com") {
            storage.setCookie(cookie)
            adopted += 1
        }
        guard adopted > 0 else { return }
        saveCookies()
        state = .signedIn
    }
    #endif

    // MARK: - Native requests

    public var isSignedIn: Bool { state == .signedIn }

    /// Performs an OLS API call. Throws a clear, actionable error when the
    /// session has lapsed — the portal answers expired sessions with its HTML
    /// login page rather than a 401.
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(base, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if http.statusCode == 401 || http.statusCode == 403 || contentType.contains("text/html") {
                state = .expired
                throw SBError.message("Your K12 sign-in expired — sign in again in this panel's settings")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SBError.message("K12 portal HTTP \(http.statusCode)")
            }
        }
        // Cookies may have been refreshed by the call.
        saveCookies()
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
