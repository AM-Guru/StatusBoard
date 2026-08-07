import Foundation
import ImageIO
import CoreGraphics
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Finds the site icon for a feed and hands back small PNG bytes.
///
/// Everything is fetched straight from the publisher's own host — no favicon
/// proxy, no third-party service — so a news panel talks only to the sites the
/// user subscribed to. Results are cached on disk per host, including the
/// "this site has no icon" answer, so a refreshing panel does not re-crawl.
public actor FaviconProvider {
    public static let shared = FaviconProvider()

    /// Icons are rendered at ~18pt; 64px covers @3x with room to spare.
    private static let pixelSize = 64
    /// Ignore anything implausibly large for an icon.
    private static let maxDownloadBytes = 1_500_000
    private static let cacheLifetime: TimeInterval = 14 * 24 * 3600

    private var memory: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init() {}

    /// - Parameters:
    ///   - site: a page on the publisher's site — the feed's own link, or any
    ///     article link from it.
    ///   - declared: the artwork the feed itself advertises (RSS
    ///     `<channel><image><url>`, Atom `<icon>`), used when the site has no
    ///     usable favicon.
    public func icon(site: URL?, declared: URL? = nil) async -> Data? {
        guard let host = site?.host ?? declared?.host, !host.isEmpty else { return nil }
        if let cached = memory[host] { return cached }
        if let stored = readCache(host: host) {
            memory[host] = stored
            return stored
        }
        if let running = inFlight[host] { return await running.value }

        let task = Task<Data?, Never> { [site, declared] in
            await Self.resolve(host: host, site: site, declared: declared)
        }
        inFlight[host] = task
        let icon = await task.value
        inFlight[host] = nil
        memory[host] = icon
        writeCache(host: host, icon: icon)
        return icon
    }

    /// Forgets every cached answer — used by the tests and by "refresh now"
    /// when a site has changed its branding.
    public func invalidate() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    // MARK: - Resolution

    private static func resolve(host: String, site: URL?, declared: URL?) async -> Data? {
        var candidates: [URL] = []
        let root = URL(string: "https://\(host)/")
        if let root {
            candidates.append(contentsOf: await declaredIcons(onPage: site ?? root))
            candidates.append(root.appendingPathComponent("favicon.ico"))
            candidates.append(root.appendingPathComponent("apple-touch-icon.png"))
        }
        if let declared { candidates.append(declared) }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.absoluteString).inserted {
            if let data = await download(candidate), let png = normalize(data) {
                return png
            }
        }
        return nil
    }

    /// The `<link rel="icon">` family from a page's markup, best first.
    private static func declaredIcons(onPage page: URL) async -> [URL] {
        guard let data = await download(page), let html = decodeHTML(data) else { return [] }
        // Only the head can carry icon links, and stopping there keeps the
        // regex off a megabyte of article markup.
        let head = html.range(of: "</head>", options: [.caseInsensitive])
            .map { String(html[html.startIndex..<$0.lowerBound]) } ?? String(html.prefix(60_000))

        var found: [(rank: Int, url: URL)] = []
        for tag in matches(of: "<link[^>]*>", in: head) {
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(separator: " ").contains(where: { $0.hasSuffix("icon") }),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines),
                                relativeTo: page)?.absoluteURL
            else { continue }
            // SVG icons don't decode into bitmaps on every platform, so they
            // rank last rather than being dropped: better a maybe than nothing.
            let isVector = url.pathExtension.lowercased() == "svg"
            let declaredSize = attribute("sizes", in: tag)
                .flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
            let rank = isVector ? -1000 : min(declaredSize, 180)
            found.append((rank, url))
        }
        return found.sorted { $0.rank > $1.rank }.map(\.url)
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("StatusBoard/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard !data.isEmpty, data.count <= maxDownloadBytes else { return nil }
        return data
    }

    private static func decodeHTML(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Re-encodes whatever the site served (ICO, PNG, JPEG, WebP) as a small
    /// PNG, which also filters out anything that isn't a decodable image.
    static func normalize(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        #if canImport(UniformTypeIdentifiers)
        let type = UTType.png.identifier as CFString
        #else
        let type = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Disk cache

    private static var cacheDirectory: URL {
        SBStorage.localSupportURL().appendingPathComponent("Favicons", isDirectory: true)
    }

    private func cacheURL(host: String) -> URL {
        // Hosts are already filesystem-safe apart from the odd IDN colon.
        let name = host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return Self.cacheDirectory.appendingPathComponent("\(name).png")
    }

    /// `.some(nil)` means "we looked and this host has no icon" — worth
    /// remembering so every refresh doesn't re-crawl the site.
    private func readCache(host: String) -> Data?? {
        let url = cacheURL(host: host)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.cacheLifetime,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return .some(data.isEmpty ? nil : data)
    }

    private func writeCache(host: String, icon: Data?) {
        let directory = Self.cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (icon ?? Data()).write(to: cacheURL(host: host), options: .atomic)
    }

    // MARK: - Tiny HTML helpers

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag))
        else { return nil }
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range])
            }
        }
        return nil
    }
}
