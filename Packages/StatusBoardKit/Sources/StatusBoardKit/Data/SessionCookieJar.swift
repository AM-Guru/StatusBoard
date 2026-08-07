import Foundation

/// A cookie jar the app owns outright, with explicit `Cookie:` headers.
///
/// `HTTPCookieStorage()` looks like it hands you a private jar. It does not.
/// A directly-instantiated storage silently drops every `setCookie` — the
/// cookie lands in `HTTPCookieStorage.shared` instead — and reading `.cookies`
/// back returns `nil`. That is exactly how the K12 sign-in could report
/// success while saving nothing and sending nothing: the sheet counted the
/// cookies it *handed over*, not the ones that were kept.
///
/// So: a plain array we control, RFC 6265 matching we can unit-test, and a
/// header we set ourselves. It also keeps the session out of the process-wide
/// shared storage, which no other part of the app should ever see.
struct SessionCookieJar: Sendable {
    private(set) var cookies: [HTTPCookie] = []

    var isEmpty: Bool { cookies.isEmpty }

    /// Cookie names only — safe to put in a diagnostic message. Never values.
    var names: [String] { cookies.map(\.name).sorted() }

    /// Stores cookies, replacing any with the same identity (name + domain +
    /// path). Returns whether anything actually changed, so callers can skip
    /// a Keychain write on the common no-op case.
    @discardableResult
    mutating func absorb(_ incoming: [HTTPCookie], now: Date = Date()) -> Bool {
        var changed = false
        for cookie in incoming {
            let index = cookies.firstIndex {
                $0.name == cookie.name
                    && $0.domain.caseInsensitiveCompare(cookie.domain) == .orderedSame
                    && $0.path == cookie.path
            }
            // An already-expired cookie is a deletion instruction, not a value.
            if let expires = cookie.expiresDate, expires <= now {
                if let index {
                    cookies.remove(at: index)
                    changed = true
                }
                continue
            }
            if let index {
                if cookies[index].value == cookie.value { continue }
                cookies[index] = cookie
            } else {
                cookies.append(cookie)
            }
            changed = true
        }
        return changed
    }

    mutating func removeAll() { cookies.removeAll() }

    /// The cookies this URL should carry, by domain, path, secure, and expiry.
    func matching(_ url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let isSecure = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !isSecure { return false }
            guard Self.domainMatches(host: host, cookieDomain: cookie.domain) else { return false }
            return Self.pathMatches(requestPath: path, cookiePath: cookie.path)
        }
    }

    /// The `Cookie:` header value for a request, or nil when nothing matches.
    func header(for url: URL, now: Date = Date()) -> String? {
        let matches = matching(url, now: now)
        guard !matches.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matches)["Cookie"]
    }

    // MARK: - Matching rules

    static func domainMatches(host: String, cookieDomain: String) -> Bool {
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if cookiePath == "/" || requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        // "/api" must not match "/apixyz", but does match "/api/v1".
        return cookiePath.hasSuffix("/")
            || requestPath.dropFirst(cookiePath.count).hasPrefix("/")
    }

    /// The registrable domain a portal's cookies are scoped to, e.g.
    /// `home.k12.com` → `k12.com`, so the SSO hop through
    /// `security-gateway.k12.com` is kept too.
    ///
    /// Naive last-two-labels: right for `k12.com` and `instructure.com`, and
    /// over-broad only for multi-part TLDs, where the cost is keeping a cookie
    /// we'd otherwise drop.
    static func registrableDomain(of hostOrURL: String) -> String {
        var text = hostOrURL.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.contains("://") { text = "https://" + text }
        let host = URL(string: text)?.host ?? hostOrURL.lowercased()
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    // MARK: - Persistence

    /// JSON-safe property dictionaries for the Keychain.
    ///
    /// Expiry is written as epoch seconds rather than an ISO string because
    /// `HTTPCookie(properties:)` wants a real `Date` for `.expires` — feeding
    /// it a string back produced a cookie that quietly lost its expiry.
    var persistable: [[String: String]] {
        cookies.map { cookie in
            var entry: [String: String] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path.isEmpty ? "/" : cookie.path,
            ]
            if cookie.isSecure { entry["secure"] = "TRUE" }
            if let expires = cookie.expiresDate {
                entry["expires"] = String(expires.timeIntervalSince1970)
            }
            return entry
        }
    }

    static func restored(from entries: [[String: String]], now: Date = Date()) -> SessionCookieJar {
        var jar = SessionCookieJar()
        jar.absorb(entries.compactMap { entry -> HTTPCookie? in
            guard let name = entry["name"], let value = entry["value"],
                  let domain = entry["domain"] else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: entry["path"] ?? "/",
            ]
            if entry["secure"] != nil { properties[.secure] = "TRUE" }
            if let seconds = entry["expires"].flatMap(Double.init) {
                properties[.expires] = Date(timeIntervalSince1970: seconds)
            }
            return HTTPCookie(properties: properties)
        }, now: now)
        return jar
    }
}
