import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

/// A live web page region. On iOS/macOS this is a real WKWebView that reloads
/// on the panel's refresh interval; on tvOS the Mac bridge renders it to an
/// image (handled by DataSourceEngine → SnapshotContentView).
struct WebClipPanelContent: View {
    @Environment(\.sbStyle) private var sbStyle
    let panel: Panel
    let record: SnapshotRecord?

    #if canImport(WebKit) && !os(tvOS)
    @Environment(\.isStaticRender) private var isStaticRender
    #endif

    var body: some View {
        #if canImport(WebKit) && !os(tvOS)
        if isStaticRender {
            // Poster export can't rasterize a live WKWebView.
            if case .image = record?.snapshot {
                SnapshotContentView(record: record, settings: panel.settings)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "safari")
                        .font(.system(size: 22))
                        .foregroundStyle(sbStyle.textSecondary)
                    Text(panel.settings.url ?? "Web clip")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(sbStyle.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let urlString = panel.settings.url, let url = URL(string: urlString) {
            WebClipWebView(url: url,
                           zoom: panel.settings.webClipZoom,
                           refreshSeconds: panel.settings.refreshSeconds,
                           selector: panel.settings.webClipSelector,
                           hideSelectors: panel.settings.webClipHideSelectors,
                           blocksAds: panel.settings.webClipBlocksAds,
                           autoLogin: panel.settings.webClipAutoLogin)
        } else {
            ErrorView(message: "Set a URL in the panel settings")
        }
        #else
        // tvOS: bridge-rendered image snapshot.
        SnapshotContentView(record: record, settings: panel.settings)
        #endif
    }
}

#if canImport(WebKit) && !os(tvOS)
#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct WebClipWebView: PlatformViewRepresentable {
    let url: URL
    let zoom: Double
    let refreshSeconds: Double
    var selector: String?
    var hideSelectors: [String] = []
    var blocksAds: Bool = true
    var autoLogin: Bool = false

    /// Blocks external-app deep links and window.open — a status board panel
    /// must never yank the user into another app.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedURL: URL?
        var clipFingerprint: String?
        var reloadTimer: Timer?
        var autoLogin = false
        /// The host the panel is configured for, so single sign-on redirects
        /// can still find the saved credential.
        var configuredHost: String?
        /// Guards against credential-submission loops when a site keeps
        /// bouncing back to its login page.
        private var loginAttempts = 0
        private var lastAttempt = Date.distantPast

        /// How long to wait before reloading a page that wouldn't load, and how
        /// many times to try, before leaving it to the panel's reload timer.
        ///
        /// That timer is at least a full refresh interval away — five minutes
        /// by default — which is a long time to show an empty panel when the
        /// usual cause is a launch that beat the network to it.
        private static let retryDelay: Duration = .seconds(5)
        private static let maxRetries = 3

        private var retries = 0
        private var retryTask: Task<Void, Never>?

        deinit {
            reloadTimer?.invalidate()
            retryTask?.cancel()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The page arrived, so a later failure starts its own retry budget.
            retries = 0
            guard autoLogin else { return }
            Task { @MainActor in await self.signInIfNeeded(webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            retryAfterFailure(webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            retryAfterFailure(webView, error: error)
        }

        private func retryAfterFailure(_ webView: WKWebView, error: Error) {
            // A navigation that was cancelled is not a page that failed to
            // arrive: it's usually this panel blocking a deep link, or one load
            // superseding another. Reloading over those would fight the page.
            let error = error as NSError
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            guard retries < Self.maxRetries else { return }
            retries += 1
            retryTask?.cancel()
            retryTask = Task { @MainActor [weak webView] in
                try? await Task.sleep(for: Self.retryDelay)
                guard !Task.isCancelled else { return }
                webView?.reload()
            }
        }

        /// Advances the sign-in one step whenever the clip lands on a login
        /// page. Portals that ask for the username first and the password on
        /// the next page are handled by running once per navigation.
        @MainActor
        private func signInIfNeeded(_ webView: WKWebView) async {
            // Back off after repeated attempts — wrong credentials shouldn't
            // turn into an endless submit loop.
            if loginAttempts >= 4, Date().timeIntervalSince(lastAttempt) < 600 { return }
            if Date().timeIntervalSince(lastAttempt) < 2 { return }

            guard let credential = WebClipCredentialStore.credential(
                forCurrentHost: webView.url?.host?.lowercased(),
                configuredHost: configuredHost) else { return }

            let raw = (try? await webView.evaluateJavaScript(
                WebClipLoginScripts.detectStageScript)) as? String ?? "none"
            let stage = WebClipLoginScripts.Stage(rawValue: raw) ?? .none
            guard stage != .none else {
                // We're through — reset so a later session can sign in again.
                loginAttempts = 0
                return
            }
            lastAttempt = Date()
            loginAttempts += 1
            _ = try? await webView.evaluateJavaScript(
                WebClipLoginScripts.fillScript(username: credential.username,
                                               password: credential.password,
                                               stage: stage))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
                return .cancel
            }
            return ["http", "https", "about"].contains(scheme) ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private var clipSource: String? {
        guard selector != nil || !hideSelectors.isEmpty else { return nil }
        return WebClipScripts.clipScript(selector: selector, hideSelectors: hideSelectors)
    }

    private var fingerprint: String {
        (selector ?? "") + "|" + hideSelectors.joined(separator: "|")
    }

    private func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        installClipScript(in: configuration.userContentController)
        coordinator.clipFingerprint = fingerprint
        let webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator.autoLogin = autoLogin
        coordinator.configuredHost = url.host?.lowercased()
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        if blocksAds {
            Task { @MainActor in
                for list in await AdBlockService.shared.currentRuleLists() {
                    webView.configuration.userContentController.add(list)
                }
                webView.reload()
            }
        }
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        #endif
        let interval = max(60, refreshSeconds)
        coordinator.reloadTimer = Timer.scheduledTimer(withTimeInterval: interval,
                                                       repeats: true) { [weak webView] _ in
            Task { @MainActor in webView?.reload() }
        }
        return webView
    }

    private func installClipScript(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        if let source = clipSource {
            controller.addUserScript(WKUserScript(source: source,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
    }

    private func update(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.autoLogin = autoLogin
        coordinator.configuredHost = url.host?.lowercased()
        webView.pageZoom = zoom
        if coordinator.clipFingerprint != fingerprint {
            coordinator.clipFingerprint = fingerprint
            installClipScript(in: webView.configuration.userContentController)
            if let source = clipSource {
                webView.evaluateJavaScript(source)
            } else {
                webView.reload()
            }
        }
        if coordinator.loadedURL != url {
            coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { update(nsView, coordinator: context.coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { update(uiView, coordinator: context.coordinator) }
    #endif
}
#endif
