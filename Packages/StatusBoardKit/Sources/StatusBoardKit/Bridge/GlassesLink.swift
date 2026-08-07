import Foundation
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Whether a pair of smart glasses is on the other end of anything, and so
/// whether the Smart Glasses screen is worth offering in the menus.
///
/// Status Board does not run on glasses and never will — there is no App Store
/// on a waveguide. SybilSight does, and it draws Status Board's boards on the
/// lenses. That makes "can I arrange the glasses?" a question about a *link*
/// rather than about this device, and it can be answered three different ways
/// depending on which machine is asking:
///
///  - **A Mac running the bridge** hears the glasses introduce themselves when
///    SybilSight subscribes, and knows their name and hardware.
///  - **An iPhone or iPad** can simply ask whether SybilSight is installed
///    beside it, which is where it would be.
///  - **Anything else, and any Mac whose wearer has walked out of the house**,
///    falls back to what was last true. Losing the arrangement screen because a
///    phone went into a pocket would be a worse answer than remembering.
///
/// Any one of them is enough. The screen also has a plain switch to force it on,
/// for arranging a board before the glasses have ever been linked.
@MainActor
@Observable
public final class GlassesLink {
    public static let shared = GlassesLink()

    private enum Keys {
        static let alwaysOffered = "sb.glasses.alwaysOffered"
        static let lastSeenName = "sb.glasses.lastSeenName"
        static let lastSeenAt = "sb.glasses.lastSeenAt"
    }

    /// How long a link is remembered after the glasses were last reachable. Long
    /// enough that a weekend away doesn't retract a screen someone has arranged,
    /// short enough that a pair sold months ago stops cluttering the menu.
    private static let memory: TimeInterval = 30 * 24 * 60 * 60

    /// The glasses subscribed *right now*, when this device is the one hosting
    /// the bridge they're subscribed to.
    public private(set) var connected: BridgeClientIdentity?

    /// What the last known pair was called, remembered across launches.
    public private(set) var lastSeenName: String?
    public private(set) var lastSeenAt: Date?

    /// Forced on by the wearer, for arranging a board before ever linking.
    public var alwaysOffered: Bool {
        didSet { defaults.set(alwaysOffered, forKey: Keys.alwaysOffered) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alwaysOffered = defaults.bool(forKey: Keys.alwaysOffered)
        lastSeenName = defaults.string(forKey: Keys.lastSeenName)
        lastSeenAt = defaults.object(forKey: Keys.lastSeenAt) as? Date
    }

    // MARK: - Reporting

    /// Called by whatever knows: the Mac bridge every time its subscriber set
    /// changes. Passing nil retracts the live link but keeps the memory of it.
    public func report(connected identity: BridgeClientIdentity?) {
        connected = identity
        guard let identity else { return }
        lastSeenName = identity.name
        lastSeenAt = Date()
        defaults.set(identity.name, forKey: Keys.lastSeenName)
        defaults.set(lastSeenAt, forKey: Keys.lastSeenAt)
    }

    /// True when SybilSight is installed on this same device — the iPhone case,
    /// where the two apps sit next to each other on one Home Screen.
    ///
    /// Requires `sybilsight` in `LSApplicationQueriesSchemes`; without it iOS
    /// answers no, which degrades to the remembered link rather than breaking.
    public var sybilSightIsInstalledHere: Bool {
        #if os(iOS)
        guard let url = URL(string: "sybilsight://") else { return false }
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }

    /// Whether the link was seen recently enough to keep offering the screen.
    public var wasSeenRecently: Bool {
        guard let lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeenAt) < Self.memory
    }

    // MARK: - What the menus ask

    /// Whether to offer the Smart Glasses screen at all.
    public var isOffered: Bool {
        alwaysOffered || connected != nil || sybilSightIsInstalledHere || wasSeenRecently
    }

    /// Whether boards are reaching the lenses this moment.
    public var isLive: Bool { connected != nil }

    /// What to call the glasses in a menu or a caption.
    public var displayName: String {
        connected?.name ?? lastSeenName ?? "Smart Glasses"
    }

    /// A one-line account of the link, for the layout editor's caption.
    public var statusDescription: String {
        if let connected {
            let hardware = connected.hardware.map { " (\($0))" } ?? ""
            return "Linked — \(connected.name)\(hardware) is showing this board."
        }
        if sybilSightIsInstalledHere {
            return "SybilSight is installed on this device. Open it and turn on Status Board to send this arrangement to the lenses."
        }
        if let lastSeenName, let lastSeenAt, wasSeenRecently {
            let stamp = lastSeenAt.formatted(date: .abbreviated, time: .shortened)
            return "Not linked right now. \(lastSeenName) last showed this board on \(stamp)."
        }
        if alwaysOffered {
            return "No glasses linked yet. Arrange the screen anyway — SybilSight picks the arrangement up the first time it subscribes to this Mac."
        }
        return "No glasses linked."
    }
}
