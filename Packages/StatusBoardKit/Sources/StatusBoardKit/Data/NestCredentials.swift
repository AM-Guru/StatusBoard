import Foundation

/// Google Device Access credentials, and the OAuth refresh that keeps them
/// working.
///
/// Unlike every other connector in Status Board, none of this goes in the
/// panel's `ConnectorConfig`. A Google refresh token is not an API key you
/// can revoke a panel at a time: it renews itself indefinitely and, on a
/// Device Access project that also has cameras or a doorbell, it reaches
/// them too. Connector settings ride along in `dashboards.json` and sync
/// through CloudKit; these stay in the Keychain on the devices that were
/// signed in, and only the non-secret project and device ids travel with a
/// board.
///
/// Setting this up is genuinely a chore — it needs a Device Access project
/// (a one-off USD 5 registration with Google), an OAuth client, and the
/// consent flow below — but it is Google's only supported route to a Nest
/// thermostat, and it means Status Board talks to Google directly rather
/// than through anything the developer runs.
@MainActor
@Observable
public final class NestCredentials {
    public static let shared = NestCredentials()

    /// Device Access project id — a UUID from the Device Access Console.
    public private(set) var projectID: String?
    /// OAuth 2.0 client id from the Google Cloud console, of type
    /// "Web application" (Device Access does not accept the iOS type).
    public private(set) var clientID: String?
    public private(set) var clientSecret: String?
    public private(set) var refreshToken: String?

    /// Cached access token. Google's last an hour; this saves a refresh
    /// round trip on every single panel fetch.
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    private static let keychainAccount = "nest.credentials"

    /// Google's documented redirect for the partner connection flow. It is a
    /// page we cannot intercept, which is exactly why the sign-in sheet asks
    /// for the code to be pasted back rather than pretending to catch it.
    nonisolated public static let defaultRedirectURI = "https://www.google.com"
    nonisolated public static let scope = "https://www.googleapis.com/auth/sdm.service"

    private init() { load() }

    public var isConfigured: Bool {
        projectID != nil && clientID != nil && clientSecret != nil && refreshToken != nil
    }

    /// Everything except the tokens — what the sign-in sheet prefills.
    nonisolated public struct Setup: Sendable, Hashable {
        public var projectID: String
        public var clientID: String
        public var clientSecret: String
        public var redirectURI: String

        public init(projectID: String = "", clientID: String = "",
                    clientSecret: String = "", redirectURI: String = defaultRedirectURI) {
            self.projectID = projectID
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
        }
    }

    public var setup: Setup {
        Setup(projectID: projectID ?? "", clientID: clientID ?? "",
              clientSecret: clientSecret ?? "")
    }

    /// The URL to open in the browser to grant access.
    ///
    /// This is Google's *partner connection* endpoint, not the ordinary
    /// OAuth one: it is what shows the Nest device picker and links the
    /// Device Access project to the account. Sending people to
    /// accounts.google.com instead produces a token that can authenticate
    /// but has no devices attached to it.
    nonisolated public static func authorizationURL(_ setup: Setup) -> URL? {
        guard !setup.projectID.isEmpty, !setup.clientID.isEmpty else { return nil }
        var components = URLComponents(
            string: "https://nestservices.google.com/partnerconnections/\(setup.projectID)/auth")
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: setup.redirectURI),
            URLQueryItem(name: "access_type", value: "offline"),
            // Without this Google reuses an earlier grant and returns no
            // refresh token at all, which fails an hour later.
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "client_id", value: setup.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
        ]
        return components?.url
    }

    /// Accepts either the bare `code=` value or the whole redirected URL it
    /// came in — people copy the address bar, and Google's own instructions
    /// tell them to.
    nonisolated public static func authorizationCode(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            return code.removingPercentEncoding ?? code
        }
        // A pasted URL that URLComponents wouldn't take, e.g. with a stray
        // fragment — fall back to finding the parameter by hand.
        if let range = trimmed.range(of: "code=") {
            let tail = trimmed[range.upperBound...]
            let code = tail.prefix { $0 != "&" && $0 != "#" && !$0.isWhitespace }
            return code.isEmpty ? nil : String(code).removingPercentEncoding
        }
        return trimmed.contains(" ") ? nil : trimmed
    }

    /// Exchanges the pasted code for tokens and stores them.
    public func signIn(setup: Setup, code: String) async throws {
        let body = [
            "client_id": setup.clientID,
            "client_secret": setup.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": setup.redirectURI,
        ]
        let json = try await Self.token(body: body)
        guard let refresh = json["refresh_token"]?.stringValue, !refresh.isEmpty else {
            throw SBError.message("Google returned no refresh token. That happens when the account has already authorized this project — revoke it under your Google Account ▸ Security ▸ Third-party apps, then try again.")
        }
        projectID = Self.normalized(setup.projectID)
        clientID = Self.normalized(setup.clientID)
        clientSecret = Self.normalized(setup.clientSecret)
        refreshToken = refresh
        accessToken = json["access_token"]?.stringValue
        accessTokenExpiry = json["expires_in"]?.doubleValue
            .map { Date().addingTimeInterval($0 - 60) }
        save()
    }

    public func clear() {
        projectID = nil
        clientID = nil
        clientSecret = nil
        refreshToken = nil
        accessToken = nil
        accessTokenExpiry = nil
        KeychainBlobStore.delete(account: Self.keychainAccount)
    }

    // MARK: - Access tokens

    /// A valid access token plus the project it belongs to, refreshing if the
    /// cached one has run out. Panels fetch off the main actor and hop here,
    /// which also serializes the refresh: several panels waking together
    /// share one round trip instead of racing to invalidate each other.
    public func authorized() async throws -> (token: String, projectID: String) {
        guard let projectID, let clientID, let clientSecret, let refreshToken else {
            throw SBError.message("Connect your Google account in the panel's settings.")
        }
        if let accessToken, let accessTokenExpiry, accessTokenExpiry > Date() {
            return (accessToken, projectID)
        }
        let json = try await Self.token(body: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let token = json["access_token"]?.stringValue else {
            throw SBError.message("Google would not renew the Nest sign-in. Connect the account again in the panel's settings.")
        }
        accessToken = token
        accessTokenExpiry = json["expires_in"]?.doubleValue
            .map { Date().addingTimeInterval($0 - 60) } ?? Date().addingTimeInterval(1800)
        // A rotated refresh token has to be kept or the next renewal fails.
        if let rotated = json["refresh_token"]?.stringValue, rotated != refreshToken {
            self.refreshToken = rotated
        }
        save()
        return (token, projectID)
    }

    nonisolated static func token(body: [String: String]) async throws -> JSONValue {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v4/token") else {
            throw SBError.message("Invalid Google token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\(encoded($0.key))=\(encoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONValue.parse(data)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Google's errors are specific and worth passing through — half
            // of setting this up is finding out which field is wrong.
            let description = json["error_description"]?.stringValue
                ?? json["error"]?.stringValue
                ?? "HTTP \(http.statusCode)"
            throw SBError.message("Google rejected the sign-in: \(description)")
        }
        return json
    }

    nonisolated private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
        projectID = Self.normalized(raw["projectID"])
        clientID = Self.normalized(raw["clientID"])
        clientSecret = Self.normalized(raw["clientSecret"])
        refreshToken = Self.normalized(raw["refreshToken"])
    }

    private func save() {
        var raw: [String: String] = [:]
        if let projectID { raw["projectID"] = projectID }
        if let clientID { raw["clientID"] = clientID }
        if let clientSecret { raw["clientSecret"] = clientSecret }
        if let refreshToken { raw["refreshToken"] = refreshToken }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        KeychainBlobStore.save(data, account: Self.keychainAccount)
    }
}
