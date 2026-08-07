import Foundation

/// Messages exchanged between the Mac bridge and subscribed devices as
/// newline-delimited JSON over TCP. A subscription starts with the client
/// sending the literal line `SB SUBSCRIBE 1`; anything else on the port is
/// treated as an HTTP request.
/// Parameters for rendering a web clip, including 1Blocker-style region
/// isolation and element hiding.
public struct WebClipSpec: Codable, Sendable, Hashable {
    public var url: String
    public var width: Double
    public var height: Double
    public var zoom: Double
    /// CSS selector to isolate — everything else is hidden and the snapshot
    /// is cropped to this element.
    public var selector: String?
    /// CSS selectors to hide.
    public var hideSelectors: [String]
    /// Block ads and trackers while rendering.
    public var blocksAds: Bool
    /// Sign in with the renderer's saved credentials when a login page appears.
    public var autoLogin: Bool

    public init(url: String, width: Double = 1280, height: Double = 720,
                zoom: Double = 1, selector: String? = nil, hideSelectors: [String] = [],
                blocksAds: Bool = true, autoLogin: Bool = false) {
        self.url = url
        self.width = width
        self.height = height
        self.zoom = zoom
        self.selector = selector
        self.hideSelectors = hideSelectors
        self.blocksAds = blocksAds
        self.autoLogin = autoLogin
    }

    public init(url: String, settings: PanelSettings, width: Double = 1280, height: Double = 720) {
        self.init(url: url, width: width, height: height,
                  zoom: settings.webClipZoom,
                  selector: settings.webClipSelector,
                  hideSelectors: settings.webClipHideSelectors,
                  blocksAds: settings.webClipBlocksAds,
                  autoLogin: settings.webClipAutoLogin)
    }
}

/// What a subscriber says it is, sent once immediately after the handshake.
///
/// The handshake line itself is deliberately left alone — an older iPhone or
/// Apple TV that never sends this still subscribes exactly as before, and is
/// simply reported as an unnamed display. What this buys is the one thing the
/// Mac could not otherwise know: whether a *pair of glasses* is reachable, which
/// is what decides if the Smart Glasses screen is worth offering in the menus.
public struct BridgeClientIdentity: Codable, Sendable, Hashable {
    /// Stable per install, so a phone that reconnects is the same client rather
    /// than a second one.
    public var id: String
    /// What to call it in the bridge console and the screen menu.
    public var name: String
    /// The `SBDeviceClass` raw value this client draws boards for, when it draws
    /// them for one particular screen. `nil` for an ordinary app subscribing for
    /// panel data.
    public var deviceClass: String?
    /// The app on the other end — "SybilSight", "Status Board".
    public var app: String?
    /// Free-text hardware description, e.g. "Even Realities G2".
    public var hardware: String?

    public init(id: String, name: String, deviceClass: String? = nil,
                app: String? = nil, hardware: String? = nil) {
        self.id = id
        self.name = name
        self.deviceClass = deviceClass
        self.app = app
        self.hardware = hardware
    }

    /// The screen this client renders, when it names a known one.
    public var device: SBDeviceClass? {
        deviceClass.flatMap(SBDeviceClass.init(rawValue:))
    }
}

public enum BridgeMessage: Codable, Sendable {
    case hello(serverName: String)
    /// A subscriber introducing itself. Sent by the client right after the
    /// handshake; ignored by servers that predate it.
    case identity(BridgeClientIdentity)
    case snapshot(key: String, record: SnapshotRecord)
    /// Every board the Mac currently holds. Sent whole rather than as a diff:
    /// boards are small, and a complete set lets a display-only device tell
    /// "this board was deleted" from "this board hasn't arrived yet" — which a
    /// stream of individual updates cannot.
    ///
    /// This is the path that works when iCloud doesn't: an Apple TV on the same
    /// network as the Mac gets its boards over Bonjour, with no account, no
    /// CloudKit container, and nothing leaving the house.
    case boards([Dashboard])
    case webClipRequest(id: String, spec: WebClipSpec)
    case webClipResponse(id: String, pngBase64: String?, error: String?)
    /// Apple TV asking the Mac for K12 schedule data.
    ///
    /// The Mac answers with the *data*, not with its session: signing in needs
    /// WebKit, which tvOS doesn't have, and the bridge is plain TCP on the
    /// local network, which is no place to put a live session cookie. The Mac
    /// re-authenticates on its own if its session has lapsed, so a display can
    /// keep showing today's classes with nothing but a Mac awake in the house.
    case k12Request(id: String, portal: String, mode: String)
    case k12Response(id: String, record: SnapshotRecord?, error: String?)

    private enum CodingKeys: String, CodingKey {
        case type, serverName, key, record, id, url, width, height, zoom
        case selector, hideSelectors, blocksAds, autoLogin, pngBase64, error
        case boards, portal, mode, identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(serverName: try container.decode(String.self, forKey: .serverName))
        case "identity":
            self = .identity(try container.decode(BridgeClientIdentity.self, forKey: .identity))
        case "snapshot":
            self = .snapshot(key: try container.decode(String.self, forKey: .key),
                             record: try container.decode(SnapshotRecord.self, forKey: .record))
        case "boards":
            self = .boards(try container.decode([Dashboard].self, forKey: .boards))
        case "webclip":
            self = .webClipRequest(
                id: try container.decode(String.self, forKey: .id),
                spec: WebClipSpec(
                    url: try container.decode(String.self, forKey: .url),
                    width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 1280,
                    height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 720,
                    zoom: try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1,
                    selector: try container.decodeIfPresent(String.self, forKey: .selector),
                    hideSelectors: try container.decodeIfPresent([String].self, forKey: .hideSelectors) ?? [],
                    blocksAds: try container.decodeIfPresent(Bool.self, forKey: .blocksAds) ?? true,
                    autoLogin: try container.decodeIfPresent(Bool.self, forKey: .autoLogin) ?? false))
        case "webclipResult":
            self = .webClipResponse(
                id: try container.decode(String.self, forKey: .id),
                pngBase64: try container.decodeIfPresent(String.self, forKey: .pngBase64),
                error: try container.decodeIfPresent(String.self, forKey: .error))
        case "k12":
            self = .k12Request(
                id: try container.decode(String.self, forKey: .id),
                portal: try container.decode(String.self, forKey: .portal),
                mode: try container.decodeIfPresent(String.self, forKey: .mode) ?? "")
        case "k12Result":
            self = .k12Response(
                id: try container.decode(String.self, forKey: .id),
                record: try container.decodeIfPresent(SnapshotRecord.self, forKey: .record),
                error: try container.decodeIfPresent(String.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Unknown message type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let serverName):
            try container.encode("hello", forKey: .type)
            try container.encode(serverName, forKey: .serverName)
        case .identity(let identity):
            try container.encode("identity", forKey: .type)
            try container.encode(identity, forKey: .identity)
        case .snapshot(let key, let record):
            try container.encode("snapshot", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(record, forKey: .record)
        case .boards(let boards):
            try container.encode("boards", forKey: .type)
            try container.encode(boards, forKey: .boards)
        case .webClipRequest(let id, let spec):
            try container.encode("webclip", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(spec.url, forKey: .url)
            try container.encode(spec.width, forKey: .width)
            try container.encode(spec.height, forKey: .height)
            try container.encode(spec.zoom, forKey: .zoom)
            try container.encodeIfPresent(spec.selector, forKey: .selector)
            if !spec.hideSelectors.isEmpty {
                try container.encode(spec.hideSelectors, forKey: .hideSelectors)
            }
            try container.encode(spec.blocksAds, forKey: .blocksAds)
            try container.encode(spec.autoLogin, forKey: .autoLogin)
        case .webClipResponse(let id, let pngBase64, let error):
            try container.encode("webclipResult", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(pngBase64, forKey: .pngBase64)
            try container.encodeIfPresent(error, forKey: .error)
        case .k12Request(let id, let portal, let mode):
            try container.encode("k12", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(portal, forKey: .portal)
            try container.encode(mode, forKey: .mode)
        case .k12Response(let id, let record, let error):
            try container.encode("k12Result", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(record, forKey: .record)
            try container.encodeIfPresent(error, forKey: .error)
        }
    }

    public static let subscribeHandshake = "SB SUBSCRIBE 1"

    public func encodedLine() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) -> BridgeMessage? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BridgeMessage.self, from: data)
    }
}

/// The body accepted by `POST /api/push` — flexible enough for one-line curl
/// calls from shell scripts and AI tools.
public struct BridgePushRequest: Codable, Sendable {
    public var key: String
    public var text: String?
    public var number: Double?
    public var unit: String?
    public var series: [SeriesPoint]?
    public var table: TableData?
    public var feed: [FeedItem]?
    public var statuses: [ServiceStatus]?
    /// When pushing numbers, keep a rolling history of this many samples and
    /// publish it under "<key>.history" for graph panels.
    public var history: Int?

    public init(key: String) {
        self.key = key
    }

    public func primarySnapshot() -> DataSnapshot? {
        if let number { return .number(number, unit: unit) }
        if let text { return .text(text) }
        if let series { return .series(SeriesData(points: series, unit: unit)) }
        if let table { return .table(table) }
        if let feed { return .feed(feed) }
        if let statuses { return .statuses(statuses) }
        return nil
    }
}
