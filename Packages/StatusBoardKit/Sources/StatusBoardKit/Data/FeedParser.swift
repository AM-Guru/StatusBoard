import Foundation

/// Minimal RSS 2.0 / Atom parser built on XMLParser.
public final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [FeedItem] = []
    private var currentElement = ""
    private var inItem = false
    private var currentTitle = ""
    private var currentLink = ""
    private var currentDate = ""
    private var currentAtomLinkHref: String?

    public static func parse(data: Data) -> [FeedItem] {
        let parser = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let urlString = settings.url, let url = URL(string: urlString) else {
            return .error("No feed URL configured")
        }
        do {
            let data = try await WebQuerySource.fetch(url: url)
            let items = parse(data: data)
            guard !items.isEmpty else { return .error("Feed contained no items") }
            return .feed(Array(items.prefix(30)))
        } catch {
            return .error(error.localizedDescription)
        }
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
        } else if inItem && name == "link", let href = attributes["href"] {
            // Atom-style <link href="..."/>
            if attributes["rel"] == nil || attributes["rel"] == "alternate" {
                currentAtomLinkHref = href
            }
        }
        currentElement = name
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch currentElement {
        case "title": currentTitle += string
        case "link": currentLink += string
        case "pubdate", "published", "updated", "dc:date": currentDate += string
        default: break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
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
