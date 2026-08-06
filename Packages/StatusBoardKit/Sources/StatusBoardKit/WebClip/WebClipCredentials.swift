import Foundation
import Security

/// Sign-in details for a web clip, stored in the **Keychain** and keyed by
/// host — never in the dashboard JSON and never synced through CloudKit, so
/// passwords don't ride along with boards you share or export.
public struct WebClipCredential: Sendable, Equatable {
    public var host: String
    public var username: String
    public var password: String

    public init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }
}

public enum WebClipCredentialStore {
    static let label = "Status Board web clip"

    /// Normalizes a page URL to the host we key credentials by.
    public static func host(for urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), let host = url.host else { return nil }
        return host.lowercased()
    }

    /// The registrable part of a host — `login.k12.com` and `learn2.k12.com`
    /// both reduce to `k12.com`. Approximated as the last two labels, which is
    /// right for the single-label TLDs these portals use.
    public static func domain(for host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    public static func save(_ credential: WebClipCredential) -> Bool {
        // Replace any existing entry for this host.
        _ = delete(host: credential.host)
        guard let data = credential.password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: credential.host,
            kSecAttrAccount as String: credential.username,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public static func load(host: String) -> WebClipCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let result = item as? [String: Any],
              let account = result[kSecAttrAccount as String] as? String,
              let data = result[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return WebClipCredential(host: host, username: account, password: password)
    }

    /// Hosts we hold a Status Board credential for.
    public static func savedHosts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let results = item as? [[String: Any]] else { return [] }
        return results.compactMap { $0[kSecAttrServer as String] as? String }
    }

    /// Picks the credential to use for the page we've actually landed on.
    ///
    /// Single sign-on means a clip of `learn2.k12.com` can be redirected to
    /// `login.k12.com`, so an exact host match isn't enough. We fall back to
    /// the panel's configured host, then to any saved credential on the same
    /// registrable domain — but never wider than that.
    public static func credential(forCurrentHost currentHost: String?,
                                  configuredHost: String?) -> WebClipCredential? {
        if let currentHost, let exact = load(host: currentHost) { return exact }
        if let configuredHost, let configured = load(host: configuredHost) { return configured }
        guard let currentHost else { return nil }
        let currentDomain = domain(for: currentHost)
        for host in savedHosts() where domain(for: host) == currentDomain {
            if let sibling = load(host: host) { return sibling }
        }
        return nil
    }

    public static func hasCredential(host: String?) -> Bool {
        guard let host else { return false }
        return load(host: host) != nil
    }

    @discardableResult
    public static func delete(host: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Login automation

public enum WebClipLoginScripts {

    /// What the current page is asking for. Portals commonly split sign-in
    /// across two pages (username, then password), so filling blindly isn't
    /// enough — we have to know which step we're on.
    public enum Stage: String, Sendable {
        case none
        case username
        case password
    }

    /// Reports the sign-in stage of the current page.
    public static let detectStageScript = """
    (function() {
      function visible(el) {
        if (!el) { return false; }
        var r = el.getBoundingClientRect();
        if (!(r.width > 0 && r.height > 0)) { return false; }
        var style = window.getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none';
      }
      var passwords = Array.prototype.filter.call(
        document.querySelectorAll('input[type="password"]'), visible);
      if (passwords.length) { return 'password'; }

      // A username-first step: a text/email field plus something to submit,
      // on a page that looks like a sign-in page.
      var users = Array.prototype.filter.call(
        document.querySelectorAll(
          'input[type="text"],input[type="email"],input[type="tel"],input:not([type])'),
        visible);
      if (!users.length) { return 'none'; }
      var hint = (location.href + ' ' + document.title + ' ' +
                  (document.body ? document.body.innerText.substring(0, 400) : '')).toLowerCase();
      var looksLikeLogin = /log\\s?in|sign\\s?in|username|user name|saml|sso|authenticate|account/.test(hint);
      var hasSubmit = !!document.querySelector(
        'button[type="submit"],input[type="submit"],button');
      return (looksLikeLogin && hasSubmit) ? 'username' : 'none';
    })();
    """

    /// Fills the current step and submits. `stage` decides which field is
    /// filled, so a username-first portal advances one page at a time.
    public static func fillScript(username: String, password: String,
                                  stage: Stage) -> String {
        """
        (function() {
          var STAGE = \(WebClipScripts.jsonString(stage.rawValue));
          function visible(el) {
            if (!el) { return false; }
            var r = el.getBoundingClientRect();
            if (!(r.width > 0 && r.height > 0)) { return false; }
            var style = window.getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none';
          }
          function setValue(el, value) {
            if (!el) { return; }
            var setter = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value').set;
            setter.call(el, value);
            // React and friends listen for events, not assignment.
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
          }
          function userFields(root) {
            return Array.prototype.filter.call(
              (root || document).querySelectorAll(
                'input[type="text"],input[type="email"],input[type="tel"],input:not([type])'),
              visible);
          }

          var form = null, filled = false;

          if (STAGE === 'password') {
            var pw = Array.prototype.filter.call(
              document.querySelectorAll('input[type="password"]'), visible)[0];
            if (!pw) { return false; }
            form = pw.form;
            // Some pages keep the username field on the password step too.
            var users = userFields(form);
            if (!users.length) { users = userFields(document); }
            if (users.length) { setValue(users[users.length - 1], \(WebClipScripts.jsonString(username))); }
            setValue(pw, \(WebClipScripts.jsonString(password)));
            filled = true;
          } else {
            var user = userFields(document)[0];
            if (!user) { return false; }
            form = user.form;
            setValue(user, \(WebClipScripts.jsonString(username)));
            filled = true;
          }
          if (!filled) { return false; }

          var button = (form || document).querySelector(
            'button[type="submit"],input[type="submit"]') ||
            (form || document).querySelector('button:not([type])');
          if (button) {
            button.click();
          } else if (form && form.submit) {
            form.submit();
          } else {
            var field = document.querySelector('input[type="password"]') || document.activeElement;
            if (field) {
              field.dispatchEvent(new KeyboardEvent('keydown',
                {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
            }
          }
          return true;
        })();
        """
    }
}
