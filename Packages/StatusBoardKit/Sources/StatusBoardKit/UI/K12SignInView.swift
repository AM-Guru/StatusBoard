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
    @State private var showsCredentials = false
    @State private var username = ""
    @State private var password = ""
    @State private var savedUsername: String?
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
                credentialSection
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
        .onAppear {
            controller.start(portal: portal)
            loadSavedCredential()
        }
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
        await K12Session.shared.adoptCookies(
            from: controller.webView.configuration.websiteDataStore, portal: portal)

        // Verifies without the silent-retry wrapper `json` puts around a
        // request: the user is right here, so a second, invisible sign-in
        // attempt would only muddy what the sheet reports back to them.
        guard let failure = await K12Session.shared.verify(portal: portal) else {
            saveCredentialIfRequested()
            onFinish()
            dismiss()
            return
        }

        let reason = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        errorMessage = """
            Signed in, but \(portal) did not accept the saved session (\(reason)).
            Check the portal address above is the one you actually signed in to, \
            then tap Done again. Your cookies were kept, so nothing is lost.
            Session: \(K12Session.shared.diagnosticSummary).
            """
    }

    // MARK: - Remembering the sign-in

    /// Portal sessions lapse, and the cookies WebKit keeps outlive them by
    /// weeks — but not forever, and not through a password change. Saving the
    /// sign-in is what lets the panel recover from *any* lapse without a person
    /// present, which is the difference between a wall display that keeps
    /// working and one that quietly stops.
    private var credentialSection: some View {
        DisclosureGroup(isExpanded: $showsCredentials) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionOff()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Text("""
                    Stored in this device's Keychain only — it is never put in a board, \
                    never exported, and never synced. Without it, Status Board can still \
                    sign back in from the portal's own saved cookies; with it, it can \
                    recover even after those are gone.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if savedUsername != nil {
                    Button("Forget Saved Sign-in", role: .destructive) {
                        WebClipCredentialStore.delete(host: credentialHost)
                        savedUsername = nil
                        username = ""
                        password = ""
                    }
                    .font(.footnote)
                }
            }
            .padding(.top, 6)
        } label: {
            Label(savedUsername.map { "Sign-in saved for \($0)" } ?? "Remember my sign-in",
                  systemImage: savedUsername == nil ? "key" : "key.fill")
                .font(.footnote)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// The host credentials are keyed by. The portal as typed, so it matches
    /// what the panel is configured with — `WebClipCredentialStore` handles the
    /// hop to the SSO host from there.
    private var credentialHost: String {
        (portal.contains("://") ? URL(string: portal)?.host : portal)?.lowercased()
            ?? portal.lowercased()
    }

    private func saveCredentialIfRequested() {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else { return }
        _ = WebClipCredentialStore.save(
            WebClipCredential(host: credentialHost, username: user, password: password))
    }

    private func loadSavedCredential() {
        savedUsername = WebClipCredentialStore.load(host: credentialHost)?.username
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
