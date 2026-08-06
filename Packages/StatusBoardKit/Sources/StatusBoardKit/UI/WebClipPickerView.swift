#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import SwiftUI
import WebKit

/// Interactive region picker: browse (and sign in), tap to select a region,
/// widen or narrow the selection through the element tree, and hide anything
/// you don't want. Ads are blocked while you work so the page you're picking
/// from looks like the panel will.
public struct WebClipPickerView: View {
    enum PickMode: String, CaseIterable {
        case browse
        case isolate
        case hide

        var label: String {
            switch self {
            case .browse: return "Browse"
            case .isolate: return "Select Region"
            case .hide: return "Hide Elements"
            }
        }
    }

    @State private var controller = PickerWebController()
    @State private var mode: PickMode = .isolate
    @State private var urlText: String
    @State private var selector: String?
    @State private var current: PickerWebController.Selection?
    @State private var hideSelectors: [String]
    @State private var blocksAds: Bool
    @State private var isPreviewing = false

    private let onSave: (_ selector: String?, _ hideSelectors: [String],
                         _ blocksAds: Bool, _ url: String) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(urlString: String,
                selector: String?,
                hideSelectors: [String],
                blocksAds: Bool = true,
                onSave: @escaping (_ selector: String?, _ hideSelectors: [String],
                                   _ blocksAds: Bool, _ url: String) -> Void) {
        self._urlText = State(initialValue: urlString)
        self._selector = State(initialValue: selector)
        self._hideSelectors = State(initialValue: hideSelectors)
        self._blocksAds = State(initialValue: blocksAds)
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                PlatformWebViewWrapper(webView: controller.webView)
                Divider()
                statusBar
            }
            .navigationTitle("Choose Web Clip Region")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Selection") {
                        onSave(selector, hideSelectors, blocksAds, urlText)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            controller.onSelectionChange = { selection in
                if let selection {
                    adopt(selection)
                } else {
                    current = nil
                }
            }
            controller.setPickingEnabled(mode != .browse)
            controller.blocksAds = blocksAds
            load()
        }
        .onDisappear { controller.teardown() }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 620)
        #endif
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("https://…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionOff()
                    .onSubmit(load)
                Button("Go", action: load)
            }
            Picker("Mode", selection: $mode) {
                ForEach(PickMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, newMode in
                controller.setPickingEnabled(newMode != .browse)
                if newMode != .isolate { endPreview() }
            }

            if mode == .isolate {
                regionControls
            } else {
                Text(instructions)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    /// Widen/narrow the current region, plus a live preview of the result.
    private var regionControls: some View {
        HStack(spacing: 10) {
            Button {
                controller.contract()
            } label: {
                Label("Narrower", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(current?.canContract != true || isPreviewing)

            Button {
                controller.expand()
            } label: {
                Label("Wider", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(current?.canExpand != true || isPreviewing)

            Spacer(minLength: 0)

            if current != nil {
                Button(isPreviewing ? "Stop Preview" : "Preview") {
                    isPreviewing ? endPreview() : startPreview()
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var instructions: String {
        switch mode {
        case .browse:
            return "Use the page normally — sign in, accept cookies, navigate. Web clips share these logins."
        case .isolate:
            return "Tap the part of the page you want the panel to show."
        case .hide:
            return "Tap anything you want gone — ads, banners, sidebars."
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let current {
                    Image(systemName: "viewfinder")
                        .foregroundStyle(SBTheme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.describedName)
                            .font(.callout)
                            .lineLimit(1)
                        Text("\(current.width) × \(current.height) points")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Clear") {
                        selector = nil
                        self.current = nil
                        controller.clearSelection()
                        endPreview()
                    }
                    .font(.callout)
                } else {
                    Text("No region selected — the panel will show the full page.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if !hideSelectors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(hideSelectors, id: \.self) { hidden in
                            Button {
                                hideSelectors.removeAll { $0 == hidden }
                                reapply()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(hidden)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(SBTheme.panelBorder, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Show this element again")
                        }
                    }
                }
                .frame(maxHeight: 30)
            }

            Toggle("Block ads and trackers (EasyList)", isOn: $blocksAds)
                .font(.callout)
                .onChange(of: blocksAds) { _, enabled in
                    controller.blocksAds = enabled
                    controller.reload()
                }
        }
        .padding(10)
    }

    // MARK: - Actions

    private func load() {
        var text = urlText.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        urlText = text
        guard let url = URL(string: text) else { return }
        controller.pendingSelector = selector
        controller.pendingHides = hideSelectors
        controller.load(url)
    }

    private func startPreview() {
        guard let selection = current else { return }
        selector = selection.selector
        isPreviewing = true
        controller.setOverlaysHidden(true)
        controller.applyClip(selector: selection.selector, hides: hideSelectors)
    }

    private func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        controller.clearClip()
        controller.setOverlaysHidden(false)
        if let selection = current {
            controller.setCurrent(selection.selector)
        }
    }

    private func reapply() {
        if isPreviewing {
            controller.applyClip(selector: selector, hides: hideSelectors)
        } else {
            controller.applyHidesOnly(hideSelectors)
        }
    }

    private func adopt(_ selection: PickerWebController.Selection) {
        switch mode {
        case .browse:
            return
        case .isolate:
            selector = selection.selector
            current = selection
        case .hide:
            if !hideSelectors.contains(selection.selector) {
                hideSelectors.append(selection.selector)
            }
            controller.clearSelection()
            reapply()
        }
    }
}

// MARK: - Web view controller

/// Owns the picker's WKWebView: injects the picker script, applies content
/// blocking, and relays selection changes back to SwiftUI.
@MainActor
@Observable
final class PickerWebController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Selection: Equatable {
        var selector: String
        var tag: String
        var text: String
        var width: Int
        var height: Int
        var canExpand: Bool
        var canContract: Bool

        var describedName: String {
            text.isEmpty ? "<\(tag)>" : text
        }
    }

    let webView: WKWebView
    @ObservationIgnored var onSelectionChange: ((Selection?) -> Void)?
    @ObservationIgnored var pendingSelector: String?
    @ObservationIgnored var pendingHides: [String] = []
    @ObservationIgnored var blocksAds = true
    @ObservationIgnored private var appliedRuleLists: [WKContentRuleList] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebClipScripts.pickerScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "sbPicker")
        webView.navigationDelegate = self
        Task { await refreshContentBlocking() }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() {
        Task {
            await refreshContentBlocking()
            webView.reload()
        }
    }

    private func refreshContentBlocking() async {
        let controller = webView.configuration.userContentController
        for list in appliedRuleLists { controller.remove(list) }
        appliedRuleLists = []
        guard blocksAds else { return }
        let lists = await AdBlockService.shared.currentRuleLists()
        for list in lists { controller.add(list) }
        appliedRuleLists = lists
    }

    // MARK: Selection

    func setCurrent(_ selector: String?) {
        let argument = selector.map { WebClipScripts.jsonString($0) } ?? "null"
        webView.evaluateJavaScript("window.__sbSetCurrent && window.__sbSetCurrent(\(argument));")
    }

    func expand() {
        webView.evaluateJavaScript("window.__sbExpand && window.__sbExpand();")
    }

    func contract() {
        webView.evaluateJavaScript("window.__sbContract && window.__sbContract();")
    }

    func setOverlaysHidden(_ hidden: Bool) {
        webView.evaluateJavaScript(
            "window.__sbSetOverlaysHidden && window.__sbSetOverlaysHidden(\(hidden ? "true" : "false"));")
    }

    func clearSelection() {
        webView.evaluateJavaScript("window.__sbClearCurrent && window.__sbClearCurrent();")
        onSelectionChange?(nil)
    }

    // MARK: Clip preview

    func applyClip(selector: String?, hides: [String]) {
        webView.evaluateJavaScript(
            WebClipScripts.clipScript(selector: selector, hideSelectors: hides))
    }

    func applyHidesOnly(_ hides: [String]) {
        webView.evaluateJavaScript(
            WebClipScripts.clipScript(selector: nil, hideSelectors: hides))
    }

    func clearClip() {
        webView.evaluateJavaScript(WebClipScripts.resetScript)
    }

    func setPickingEnabled(_ enabled: Bool) {
        webView.evaluateJavaScript("""
        window.__sbPickEnabled = \(enabled ? "true" : "false");
        (function(){ var o = document.getElementById('__sb_pick_hover');
          if (o && !window.__sbPickEnabled) { o.style.display = 'none'; } })();
        """)
    }

    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sbPicker")
        webView.navigationDelegate = nil
        onSelectionChange = nil
    }

    // MARK: Delegates

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let event = body["event"] as? String ?? "selected"
        if event == "cleared" {
            Task { @MainActor in self.onSelectionChange?(nil) }
            return
        }
        guard let selector = body["selector"] as? String, !selector.isEmpty else { return }
        let selection = Selection(
            selector: selector,
            tag: body["tag"] as? String ?? "",
            text: body["text"] as? String ?? "",
            width: (body["width"] as? NSNumber)?.intValue ?? 0,
            height: (body["height"] as? NSNumber)?.intValue ?? 0,
            canExpand: (body["canExpand"] as? NSNumber)?.boolValue ?? false,
            canContract: (body["canContract"] as? NSNumber)?.boolValue ?? false)
        Task { @MainActor in self.onSelectionChange?(selection) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Restore hides immediately; restore the selection outline so the
            // user can keep adjusting where they left off.
            if !self.pendingHides.isEmpty {
                self.applyHidesOnly(self.pendingHides)
            }
            if let selector = self.pendingSelector {
                self.setCurrent(selector)
            }
        }
    }
}

/// Wraps an externally-owned WKWebView.
struct PlatformWebViewWrapper {
    let webView: WKWebView
}

#if os(macOS)
extension PlatformWebViewWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension PlatformWebViewWrapper: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
#endif
