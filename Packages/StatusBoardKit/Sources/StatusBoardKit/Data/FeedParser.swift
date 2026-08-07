import Foundation

/// Everything one feed document tells us: its items plus the metadata that
/// lets a merged panel label and illustrate them.
public struct ParsedFeed: Sendable {
    public var title: String?
    /// The publisher's own site, from `<channel><link>` or Atom's alternate
    /// link — the page whose favicon represents this feed.
    public var siteLink: URL?
    /// Artwork the feed advertises itself: RSS `<channel><image><url>`, or
    /// Atom `<icon>` / `<logo>`.
    public var iconURL: URL?
    public var items: [FeedItem]

    public init(title: String? = nil, siteLink: URL? = nil, iconURL: URL? = nil,
                items: [FeedItem] = []) {
        self.title = title
        self.siteLink = siteLink
        self.iconURL = iconURL
        self.items = items
    }
}

/// Minimal RSS 2.0 / Atom parser built on XMLParser.
public final class FeedParser: NSObject, XMLParserDelegate {
    /// At most this many items are taken from any single feed, so one prolific
    /// source can't crowd the others out of a merged panel.
    static let perSourceLimit = 25
    /// How many merged items a panel keeps.
    static let mergedLimit = 60

    private var items: [FeedItem] = []
    private var currentElement = ""
    private var inItem = false
    /// Depth inside `<image>` — its `<title>`/`<link>` must not be mistaken
    /// for the channel's own.
    private var imageDepth = 0
    private var currentTitle = ""
    private var currentLink = ""
    private var currentDate = ""
    private var currentAtomLinkHref: String?
    private var channelTitle = ""
    private var channelLink = ""
    private var channelAtomLinkHref: String?
    private var channelIconText = ""
    private var imageURLText = ""

    public static func parse(data: Data) -> [FeedItem] {
        parseFeed(data: data).items
    }

    public static func parseFeed(data: Data) -> ParsedFeed {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.result()
    }

    // MARK: - Fetching

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        let sources = settings.activeFeedSources
        guard !sources.isEmpty else { return .error("No feed URL configured") }
        let wantsIcons = settings.feedShowsSourceIcons

        var loaded: [(index: Int, feed: [FeedItem])] = []
        var failures: [String] = []

        await withTaskGroup(of: (Int, Result<[FeedItem], FeedLoadError>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    (index, await load(source: source, wantsIcon: wantsIcons))
                }
            }
            for await (index, result) in group {
                switch result {
                case .success(let items): loaded.append((index, items))
                case .failure(let error): failures.append(error.message)
                }
            }
        }

        let merged = merge(loaded)
        guard !merged.isEmpty else {
            // Nothing to show, so the panel says why rather than sitting blank.
            return .error(failures.isEmpty
                          ? "Feed contained no items"
                          : failures.prefix(3).joined(separator: "\n"))
        }
        return .feed(merged)
    }

    struct FeedLoadError: Error {
        var message: String
    }

    /// Interleaves every source newest-first. Undated items keep their feed's
    /// own order and sink below everything that carries a timestamp.
    static func merge(_ loaded: [(index: Int, feed: [FeedItem])]) -> [FeedItem] {
        let ranked = loaded.flatMap { source in
            source.feed.enumerated().map { (item: $0.element, source: source.index, position: $0.offset) }
        }
        let sorted = ranked.sorted { lhs, rhs in
            let left = lhs.item.published
            let right = rhs.item.published
            switch (left, right) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                // Same instant, or neither dated: fall back to a stable order
                // so a refresh doesn't reshuffle the list under the reader.
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                return lhs.source < rhs.source
            }
        }

        var seen = Set<String>()
        var merged: [FeedItem] = []
        for entry in sorted {
            // The same story syndicated into two feeds should appear once.
            let key = entry.item.link.map(dedupeKey) ?? entry.item.title.lowercased()
            guard seen.insert(key).inserted else { continue }
            merged.append(entry.item)
            if merged.count == mergedLimit { break }
        }
        return merged
    }

    /// Campaign tags a feed appends to its links, which differ between feeds
    /// carrying the same article. Anything else in the query is left alone —
    /// plenty of sites identify an article entirely by a query parameter
    /// (Apple Developer News is `/news/?id=…`), and stripping the whole query
    /// would merge a site's entire feed into one row.
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "ref_src",
        "at_medium", "at_campaign", "cmpid", "spm",
    ]

    static func dedupeKey(_ link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed.lowercased() }
        components.fragment = nil
        // http/https and www. variants of one article are one article.
        components.scheme = nil
        components.host = components.host?.lowercased()
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let kept = components.queryItems?.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        components.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        var key = components.string ?? trimmed
        if key.hasSuffix("/") { key.removeLast() }
        return key
    }

    private static func load(source: FeedSource, wantsIcon: Bool) async -> Result<[FeedItem], FeedLoadError> {
        let address = source.trimmedURL
        guard let url = URL(string: address), url.host != nil else {
            return .failure(FeedLoadError(message: "\(displayName(for: source)): not a valid URL"))
        }
        do {
            let data = try await WebQuerySource.fetch(url: url)
            let feed = parseFeed(data: data)
            guard !feed.items.isEmpty else {
                return .failure(FeedLoadError(message: "\(displayName(for: source, feed: feed)): no items"))
            }
            let name = displayName(for: source, feed: feed, url: url)
            var icon: Data?
            if wantsIcon {
                // The publisher's own site first; a feed hosted on a relay
                // (Feedburner and friends) would otherwise wear its logo.
                let site = feed.siteLink
                    ?? feed.items.compactMap { $0.link.flatMap(URL.init(string:)) }.first
                    ?? url
                icon = await FaviconProvider.shared.icon(site: site, declared: feed.iconURL)
            }
            let items = feed.items.prefix(perSourceLimit).map { item -> FeedItem in
                var item = item
                item.sourceName = name
                item.sourceIcon = icon
                return item
            }
            return .success(Array(items))
        } catch {
            return .failure(FeedLoadError(
                message: "\(displayName(for: source, url: url)): \(error.localizedDescription)"))
        }
    }

    /// What to call a feed: the user's own label, else the name the feed gives
    /// itself, else its host.
    static func displayName(for source: FeedSource, feed: ParsedFeed? = nil, url: URL? = nil) -> String {
        let custom = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if let title = feed?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let host = (url ?? URL(string: source.trimmedURL))?.host ?? source.trimmedURL
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - XMLParserDelegate

    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            inItem = true
            currentTitle = ""
            currentLink = ""
            currentDate = ""
            currentAtomLinkHref = nil
        } else if name == "image" {
            imageDepth += 1
        } else if name == "link", let href = attributes["href"] {
            // Atom-style <link href="..."/>, in an entry or at feed level.
            if attributes["rel"] == nil || attributes["rel"] == "alternate" {
                if inItem {
                    currentAtomLinkHref = href
                } else if imageDepth == 0, channelAtomLinkHref == nil {
                    channelAtomLinkHref = href
                }
            }
        }
        currentElement = name
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem {
            switch currentElement {
            case "title": currentTitle += string
            case "link": currentLink += string
            case "pubdate", "published", "updated", "dc:date": currentDate += string
            default: break
            }
            return
        }
        if imageDepth > 0 {
            // <channel><image><url> — the feed's own artwork.
            if currentElement == "url" { imageURLText += string }
            return
        }
        switch currentElement {
        case "title": channelTitle += string
        case "link": channelLink += string
        case "icon", "logo": channelIconText += string
        default: break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
        if name == "image" {
            imageDepth = max(0, imageDepth - 1)
            currentElement = ""
            return
        }
        guard name == "item" || name == "entry" else {
            currentElement = ""
            return
        }
        inItem = false
        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let link = currentAtomLinkHref
            ?? (currentLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : currentLink.trimmingCharacters(in: .whitespacesAndNewlines))
        items.append(FeedItem(title: title, link: link,
                              published: Self.parseDate(currentDate)))
    }

    private func result() -> ParsedFeed {
        let title = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = channelAtomLinkHref
            ?? channelLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconText = channelIconText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? imageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            : channelIconText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedFeed(title: title.isEmpty ? nil : title,
                          siteLink: site.isEmpty ? nil : URL(string: site),
                          iconURL: iconText.isEmpty ? nil : URL(string: iconText),
                          items: items)
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    private static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = rfc822.date(from: text) { return date }
        return try? Date(text, strategy: .iso8601)
    }
}
