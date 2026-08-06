#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import SwiftUI
import WebKit

/// One-time sign-in for the K12 portal.
///
/// This is the *only* place Status Board shows the portal's web UI — the same
/// role an OAuth sheet plays. Once you're through, the session cookies are
/// copied into the app's native session and every panel afterwards talks to
/// the API directly over `URLSession`.
public struct K12SignInView: View {
    let portal: String
    let onFinish: () -> Void

    @State private var controller = K12SignInController()
    @State private var isChecking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    public init(portal: String = K12Session.defaultPortal, onFinish: @escaping () -> Void) {
        self.portal = portal
        self.onFinish = onFinish
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                if let errorMessage {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12))
                }
                Divider()
                PlatformWebViewWrapper(webView: controller.webView)
            }
            .navigationTitle("Sign in to K12")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChecking ? "Checking…" : "Done") {
                        Task { await finish() }
                    }
                    .disabled(isChecking)
                }
            }
        }
        .onAppear { controller.start(portal: portal) }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 640)
        #endif
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(SBTheme.accent)
            Text("Sign in normally. Status Board keeps only the session cookie — in the Keychain — and reads your schedule through the portal's API afterwards.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    /// Adopts whatever session the web view ended up with, then verifies it by
    /// making a real API call before claiming success.
    ///
    /// A failure used to do nothing at all — `try?` swallowed the reason, the
    /// button flicked back to "Done", and there was no way to tell what went
    /// wrong. Every path now either succeeds or says why.
    private func finish() async {
        isChecking = true
        defer { isChecking = false }
        errorMessage = nil
        await K12Session.shared.adoptCookies(from: controller.webView.configuration.websiteDataStore)

        // OLS and Canvas answer on different paths, and this sheet is used for
        // both. Either one proving the session is good is enough.
        let probes = ["/api/canvas/events/classes", "/api/v1/users/self"]
        var lastError: Error?
        for path in probes {
            do {
                _ = try await K12Session.shared.json(path: path, portal: portal)
                onFinish()
                dismiss()
                return
            } catch {
                lastError = error
            }
        }

        let reason = (lastError as? LocalizedError)?.errorDescription
            ?? lastError?.localizedDescription ?? "no response"
        errorMessage = """
            Signed in, but \(portal) did not accept the saved session (\(reason)).
            Check the portal address above is the one you actually signed in to,             then tap Done again. Your cookies were kept, so nothing is lost.
            """
    }
}

@MainActor
@Observable
final class K12SignInController {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        // A persistent store so the portal can keep you signed in.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    func start(portal: String) {
        var text = portal
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        webView.load(URLRequest(url: url))
    }
}
#endif
