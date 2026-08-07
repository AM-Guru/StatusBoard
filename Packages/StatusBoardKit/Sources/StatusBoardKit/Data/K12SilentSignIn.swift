#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import Foundation
import WebKit

/// Signs back in to the K12 portal with nobody watching.
///
/// The sign-in sheet runs in WebKit's **persistent** data store, so after you
/// have signed in once the portal's own long-lived cookies are still sitting
/// there — the same ones that keep you signed in when you reopen Safari. The
/// session cookie the API needs is short-lived and lapses overnight; those
/// outlive it. Loading the portal offscreen is enough for the portal to hand
/// out a fresh session cookie, which is then copied into `K12Session` exactly
/// as the sheet does it.
///
/// When even those have been dropped, the portal shows its login form. If you
/// chose "Remember my sign-in", the saved credentials are filled in the same
/// way web clips log themselves in — including the username-then-password
/// two-step the K12 SSO host uses.
///
/// Nothing here is shown to anyone: no window, no sheet, no interaction.
@MainActor
public final class K12SilentSignIn: NSObject, WKNavigationDelegate {
    public static let shared = K12SilentSignIn()

    /// How long a single page load may take before it's abandoned.
    private static let loadTimeout: Duration = .seconds(25)
    /// Sign-in pages are multi-step; this caps the walk through them.
    private static let maxLoginSteps = 3

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Re-establishes the session for `portal`, returning whether the portal
    /// then accepted it. Safe to call from `K12Session.recoverSession`, which
    /// already guarantees only one runs at a time.
    public func refresh(portal: String) async -> Bool {
        var text = portal.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return false }

        let webView = makeWebView()
        defer { teardown() }

        guard await load(url, in: webView) else { return false }
        // Client-side portals paint the login form after the load finishes.
        try? await Task.sleep(for: .seconds(1))

        // Already signed in? Then the cookies are there for the taking, and no
        // password needs to be touched at all.
        if await adoptAndVerify(webView: webView, portal: portal) { return true }

        guard let credential = WebClipCredentialStore.credential(
            forCurrentHost: webView.url?.host?.lowercased(),
            configuredHost: URL(string: text)?.host?.lowercased()) else { return false }

        for _ in 0..<Self.maxLoginSteps {
            let raw = (try? await webView.evaluateJavaScript(
                WebClipLoginScripts.detectStageScript)) as? String ?? "none"
            guard let stage = WebClipLoginScripts.Stage(rawValue: raw), stage != .none else { break }
            _ = try? await webView.evaluateJavaScript(
                WebClipLoginScripts.fillScript(username: credential.username,
                                               password: credential.password,
                                               stage: stage))
            // The submit navigates; give the next step time to arrive.
            try? await Task.sleep(for: .seconds(5))
            if await adoptAndVerify(webView: webView, portal: portal) { return true }
        }
        return false
    }

    /// Copies whatever cookies the web view now holds and asks the portal
    /// whether they work. Only a real API answer counts as signed in.
    private func adoptAndVerify(webView: WKWebView, portal: String) async -> Bool {
        await K12Session.shared.adoptCookies(
            from: webView.configuration.websiteDataStore, portal: portal)
        return await K12Session.shared.verify(portal: portal) == nil
    }

    // MARK: - Offscreen web view

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The same persistent store the sign-in sheet uses — that store *is*
        // the cached sign-in this whole class exists to spend.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation = nil
    }

    /// Loads a URL, resolving when the navigation finishes, fails, or takes too
    /// long. The timeout is not optional: a portal that never answers would
    /// otherwise hold the recovery task — and every panel waiting on it —
    /// suspended forever.
    private func load(_ url: URL, in webView: WKWebView) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        self.continuation = continuation
                        webView.load(URLRequest(url: url))
                    }
                    return true
                } onCancel: {
                    Task { @MainActor in self.resumeLoad() }
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.loadTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func resumeLoad() {
        continuation?.resume()
        continuation = nil
    }

    // A failed navigation is still worth continuing from: portals redirect
    // through hosts that cancel their own loads, and the page that matters is
    // whichever one we ended up on.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoad()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: Error) {
        resumeLoad()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        resumeLoad()
    }
}
#endif
