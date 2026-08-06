#if !os(tvOS) && !os(watchOS)
import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Copy and paste panels as JSON. Because the payload is plain text on the
/// system pasteboard, Universal Clipboard carries a panel from an iPhone
/// straight into the Mac app — and pasting into a text editor gives you a
/// readable, shareable panel definition.
public enum PanelPasteboard {
    /// Marker so we only treat our own JSON as a pastable panel.
    static let marker = "statusboard.panel"

    struct Envelope: Codable {
        var kind: String
        var panel: Panel
    }

    public static func encode(_ panel: Panel) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Envelope(kind: marker, panel: panel)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> Panel? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8) else { return nil }
        if let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.kind == marker {
            return envelope.panel
        }
        // Also accept a bare panel object, so hand-written JSON works.
        return try? decoder.decode(Panel.self, from: data)
    }

    // MARK: - System pasteboard

    public static func copy(_ panel: Panel) {
        guard let text = encode(panel) else { return }
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// The panel currently on the pasteboard, if any.
    public static func paste() -> Panel? {
        #if canImport(AppKit)
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        #elseif canImport(UIKit)
        guard let text = UIPasteboard.general.string else { return nil }
        #else
        let text = ""
        #endif
        return decode(text)
    }

    /// Cheap check for enabling a Paste command without decoding every time.
    public static var hasPanel: Bool {
        #if canImport(AppKit)
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        #elseif canImport(UIKit)
        guard let text = UIPasteboard.general.string else { return false }
        #else
        let text = ""
        #endif
        return text.contains(marker)
    }
}
#endif
