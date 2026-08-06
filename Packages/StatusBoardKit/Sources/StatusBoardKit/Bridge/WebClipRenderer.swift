#if os(macOS)
import Foundation
import WebKit
import AppKit

/// Renders a web page to PNG in an offscreen WKWebView. Used by the bridge to
/// serve web clips to Apple TV, which has no WebKit.
@MainActor
public final class WebClipRenderer: NSObject, WKNavigationDelegate {
    public static let shared = WebClipRenderer()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isBusy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    public func render(spec: WebClipSpec) async throws -> Data {
        guard let url = URL(string: spec.url), url.scheme?.hasPrefix("http") == true else {
            throw SBError.message("Invalid URL")
        }
        let size = CGSize(width: spec.width, height: spec.height)
        // Serialize renders through a simple FIFO.
        if isBusy {
            await withCheckedContinuation { queue.append($0) }
        }
        isBusy = true
        defer {
            isBusy = false
            if !queue.isEmpty { queue.removeFirst().resume() }
        }

        let webView = makeWebView(size: size, zoom: spec.zoom)
        defer { teardown() }

        if spec.blocksAds {
            for list in await AdBlockService.shared.currentRuleLists() {
                webView.configuration.userContentController.add(list)
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                // The continuation must resume on cancellation too — otherwise
                // a page that never fires a delegate callback would leave this
                // child suspended and the group exit would hang forever.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.continuation = continuation
                        webView.load(URLRequest(url: url))
                    }
                } onCancel: {
                    Task { @MainActor in
                        self.continuation?.resume(throwing: CancellationError())
                        self.continuation = nil
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw SBError.message("Timed out loading page")
            }
            try await group.next()
            group.cancelAll()
        }

        // Give client-side rendering a beat to settle.
        try await Task.sleep(for: .seconds(1))

        // If the page bounced to a sign-in form and this clip is allowed to
        // authenticate, log in with the Mac's saved credentials and continue.
        // Two passes so username-then-password portals get through.
        if spec.autoLogin,
           let credential = WebClipCredentialStore.credential(
               forCurrentHost: webView.url?.host?.lowercased(),
               configuredHost: URL(string: spec.url)?.host?.lowercased()) {
            for _ in 0..<2 {
                let raw = (try? await webView.evaluateJavaScript(
                    WebClipLoginScripts.detectStageScript)) as? String ?? "none"
                guard let stage = WebClipLoginScripts.Stage(rawValue: raw),
                      stage != .none else { break }
                _ = try? await webView.evaluateJavaScript(
                    WebClipLoginScripts.fillScript(username: credential.username,
                                                   password: credential.password,
                                                   stage: stage))
                try await Task.sleep(for: .seconds(5))
            }
        }

        // Apply region isolation / element hiding, then crop to the element.
        var snapshotRect = CGRect(origin: .zero, size: size)
        if spec.selector != nil || !spec.hideSelectors.isEmpty {
            _ = try? await webView.evaluateJavaScript(
                WebClipScripts.clipScript(selector: spec.selector,
                                          hideSelectors: spec.hideSelectors))
            try await Task.sleep(for: .milliseconds(300))
            if let selector = spec.selector,
               let rect = try? await webView.evaluateJavaScript(
                   WebClipScripts.rectScript(selector: selector)) as? [Double],
               rect.count == 4, rect[2] > 1, rect[3] > 1 {
                // CSS pixels → view points (pageZoom scales layout coordinates).
                let zoom = spec.zoom
                let cropped = CGRect(x: rect[0] * zoom, y: rect[1] * zoom,
                                     width: rect[2] * zoom, height: rect[3] * zoom)
                let clamped = cropped.intersection(CGRect(origin: .zero, size: size))
                if !clamped.isEmpty { snapshotRect = clamped }
            }
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = snapshotRect
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SBError.message("Could not encode snapshot")
        }
        return png
    }

    private func makeWebView(size: CGSize, zoom: Double) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size),
                                configuration: configuration)
        webView.navigationDelegate = self
        if zoom != 1 { webView.pageZoom = zoom }
        // WKWebView needs a window to reliably paint; keep it ordered out.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        self.webView = webView
        self.window = window
        return webView
    }

    private func teardown() {
        webView?.navigationDelegate = nil
        webView = nil
        window?.contentView = nil
        window = nil
        continuation = nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
