import Foundation
import CryptoKit
import SwiftUI
import Testing
@testable import StatusBoardKit

@Suite struct JSONPathTests {
    let sample = try! JSONValue.parse("""
    {
      "data": {
        "count": 42,
        "items": [
          {"name": "a", "price": 1.5},
          {"name": "b", "price": 2.5},
          {"name": "c", "price": 3.0}
        ]
      }
    }
    """)

    @Test func simpleKeyPath() {
        #expect(JSONPath.first("data.count", in: sample)?.doubleValue == 42)
        #expect(JSONPath.first("$.data.count", in: sample)?.doubleValue == 42)
    }

    @Test func arrayIndexing() {
        #expect(JSONPath.first("data.items[1].name", in: sample)?.stringValue == "b")
        #expect(JSONPath.first("data.items[-1].name", in: sample)?.stringValue == "c")
    }

    @Test func wildcardFanOut() {
        let prices = JSONPath.evaluate("data.items[*].price", in: sample)
            .compactMap(\.doubleValue)
        #expect(prices == [1.5, 2.5, 3.0])
    }

    @Test func missingPathIsEmpty() {
        #expect(JSONPath.evaluate("data.nope.really", in: sample).isEmpty)
    }
}

@Suite struct ModelRoundtripTests {
    @Test func dashboardCodableRoundtrip() throws {
        var board = Dashboard.starter()
        // ISO-8601 encoding is whole-second; normalize dates so equality holds.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        board.createdAt = now
        board.modifiedAt = now
        for index in board.panels.indices {
            board.panels[index].settings.targetDate = board.panels[index].settings.targetDate == nil ? nil : now
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(board)
        let decoded = try decoder.decode(Dashboard.self, from: data)
        #expect(decoded == board)
    }

    @Test func snapshotCodableRoundtrip() throws {
        let snapshots: [DataSnapshot] = [
            .text("hello"),
            .number(42.5, unit: "%"),
            .series(SeriesData(points: [SeriesPoint(label: "a", value: 1)], unit: nil)),
            .table(TableData(columns: ["x"], rows: [["1"]])),
            .statuses([ServiceStatus(name: "api", state: .up)]),
            .error("boom"),
        ]
        for snapshot in snapshots {
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(DataSnapshot.self, from: data)
            #expect(decoded == snapshot)
        }
    }

    /// A full board must grow rather than stacking the new panel on top of an
    /// existing one — the starter board ships completely full.
    @Test func fullBoardGrowsInsteadOfOverlapping() {
        var board = Dashboard.starter()
        #expect(board.freeFrame(width: 2, height: 1) == nil)
        let originalRows = board.grid.rows

        let frame = board.makeRoom(width: 2, height: 1)
        #expect(board.grid.rows == originalRows + 1)
        #expect(frame.y == originalRows)
        #expect(!board.panels.contains { $0.frame.intersects(frame) })
    }

    @Test func makeRoomUsesGapsBeforeGrowing() {
        var board = Dashboard(name: "t")
        board.panels.append(Panel(kind: .text, title: "a",
                                  frame: GridRect(x: 0, y: 0, width: 2, height: 1)))
        let rows = board.grid.rows
        let frame = board.makeRoom(width: 2, height: 1)
        #expect(board.grid.rows == rows)
        #expect(frame == GridRect(x: 2, y: 0, width: 2, height: 1))
    }

    @Test func firstFreeFrameAvoidsOverlap() {
        var board = Dashboard(name: "t")
        board.panels.append(Panel(kind: .text, title: "a",
                                  frame: GridRect(x: 0, y: 0, width: 2, height: 1)))
        let frame = board.firstFreeFrame(width: 2, height: 1)
        #expect(frame == GridRect(x: 2, y: 0, width: 2, height: 1))
    }
}

@Suite struct HTTPMessageTests {
    @Test func parsesPostWithBody() {
        let raw = "POST /api/push HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nabcd"
        let request = HTTPRequest.parse(from: Data(raw.utf8))
        #expect(request?.method == "POST")
        #expect(request?.path == "/api/push")
        #expect(request?.body == Data("abcd".utf8))
    }

    @Test func incompleteBodyReturnsNil() {
        let raw = "POST /api/push HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"
        #expect(HTTPRequest.parse(from: Data(raw.utf8)) == nil)
    }

    @Test func queryStringStripped() {
        let raw = "GET /api/keys?x=1 HTTP/1.1\r\n\r\n"
        #expect(HTTPRequest.parse(from: Data(raw.utf8))?.path == "/api/keys")
    }
}

@Suite struct FeedParserTests {
    @Test func parsesRSS() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>T</title>
        <item><title>First Post</title><link>https://example.com/1</link>
        <pubDate>Tue, 05 Aug 2025 10:00:00 +0000</pubDate></item>
        <item><title>Second</title><link>https://example.com/2</link></item>
        </channel></rss>
        """
        let items = FeedParser.parse(data: Data(xml.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "First Post")
        #expect(items[0].link == "https://example.com/1")
        #expect(items[0].published != nil)
    }

    @Test func parsesAtom() {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        <entry><title>Atom Entry</title><link href="https://example.com/a"/>
        <updated>2025-08-05T10:00:00Z</updated></entry>
        </feed>
        """
        let items = FeedParser.parse(data: Data(xml.utf8))
        #expect(items.count == 1)
        #expect(items[0].title == "Atom Entry")
        #expect(items[0].link == "https://example.com/a")
    }

    /// The channel's own title, site link and artwork name and illustrate the
    /// feed in a merged panel — and must not be confused with an item's.
    @Test func parsesChannelMetadata() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
        <title>Example News</title><link>https://example.com/</link>
        <image><url>https://example.com/logo.png</url><title>Logo</title>
        <link>https://example.com/logo</link></image>
        <item><title>Story</title><link>https://example.com/1</link></item>
        </channel></rss>
        """
        let feed = FeedParser.parseFeed(data: Data(xml.utf8))
        #expect(feed.title == "Example News")
        #expect(feed.siteLink?.absoluteString == "https://example.com/")
        #expect(feed.iconURL?.absoluteString == "https://example.com/logo.png")
        #expect(feed.items.count == 1)
    }

    @Test func parsesAtomIconAndSiteLink() {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Atom Site</title>
        <link href="https://atom.example.com/" rel="alternate"/>
        <icon>https://atom.example.com/icon.png</icon>
        <entry><title>E</title><link href="https://atom.example.com/e"/></entry>
        </feed>
        """
        let feed = FeedParser.parseFeed(data: Data(xml.utf8))
        #expect(feed.title == "Atom Site")
        #expect(feed.siteLink?.absoluteString == "https://atom.example.com/")
        #expect(feed.iconURL?.absoluteString == "https://atom.example.com/icon.png")
    }
}

@Suite struct FeedMergeTests {
    private func item(_ title: String, minutesAgo: Int?, link: String? = nil) -> FeedItem {
        FeedItem(title: title,
                 link: link ?? "https://example.com/\(title)",
                 published: minutesAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - Double($0) * 60) })
    }

    @Test func interleavesSourcesNewestFirst() {
        let merged = FeedParser.merge([
            (index: 0, feed: [item("a1", minutesAgo: 10), item("a2", minutesAgo: 50)]),
            (index: 1, feed: [item("b1", minutesAgo: 30), item("b2", minutesAgo: 90)]),
        ])
        #expect(merged.map(\.title) == ["a1", "b1", "a2", "b2"])
    }

    /// Undated items still have to appear — just below everything timestamped.
    @Test func undatedItemsSinkToTheBottom() {
        let merged = FeedParser.merge([
            (index: 0, feed: [item("undated", minutesAgo: nil)]),
            (index: 1, feed: [item("dated", minutesAgo: 500)]),
        ])
        #expect(merged.map(\.title) == ["dated", "undated"])
    }

    @Test func dropsTheSameStorySyndicatedTwice() {
        let merged = FeedParser.merge([
            (index: 0, feed: [item("original", minutesAgo: 10, link: "https://news.example.com/story")]),
            (index: 1, feed: [item("copy", minutesAgo: 20,
                                   link: "https://news.example.com/story/?utm_source=feed")]),
        ])
        #expect(merged.map(\.title) == ["original"])
    }

    /// Some sites identify an article only by a query parameter — Apple
    /// Developer News is `/news/?id=…` — so those must stay distinct.
    @Test func keepsArticlesThatDifferOnlyInTheirQuery() {
        let merged = FeedParser.merge([
            (index: 0, feed: [
                item("first", minutesAgo: 10, link: "https://developer.apple.com/news/?id=aaa"),
                item("second", minutesAgo: 20, link: "https://developer.apple.com/news/?id=bbb"),
            ]),
        ])
        #expect(merged.map(\.title) == ["first", "second"])
    }

    @Test func mergesAcrossSchemeAndHostVariants() {
        #expect(FeedParser.dedupeKey("http://www.example.com/story/#top")
                == FeedParser.dedupeKey("https://example.com/story"))
    }

    @Test func keepsAtMostTheMergedLimit() {
        let many = (0..<80).map { item("i\($0)", minutesAgo: $0) }
        #expect(FeedParser.merge([(index: 0, feed: many)]).count == FeedParser.mergedLimit)
    }

    @Test func namesAFeedFromItsOwnTitleWhenUnlabelled() {
        let source = FeedSource(url: "https://feeds.example.com/rss")
        #expect(FeedParser.displayName(for: source) == "feeds.example.com")
        #expect(FeedParser.displayName(for: source, feed: ParsedFeed(title: "Example News")) == "Example News")
        var named = source
        named.name = "My News"
        #expect(FeedParser.displayName(for: named, feed: ParsedFeed(title: "Example News")) == "My News")
    }
}

@Suite struct FeedSourceSettingsTests {
    /// A panel saved before multi-feed support keeps working, and its single
    /// URL becomes the first editable row.
    @Test func legacyURLActsAsASingleSource() {
        var settings = PanelSettings()
        settings.url = "https://example.com/rss"
        #expect(settings.activeFeedSources.map(\.url) == ["https://example.com/rss"])
        settings.migrateFeedSourcesIfNeeded()
        #expect(settings.feedSources.count == 1)
        #expect(settings.feedSources[0].url == "https://example.com/rss")
        // Migration is idempotent.
        settings.migrateFeedSourcesIfNeeded()
        #expect(settings.feedSources.count == 1)
    }

    @Test func configuredSourcesWinOverTheLegacyURL() {
        var settings = PanelSettings()
        settings.url = "https://old.example.com/rss"
        settings.feedSources = [
            FeedSource(url: "https://a.example.com/rss"),
            FeedSource(name: "Muted", url: "https://b.example.com/rss", isEnabled: false),
            FeedSource(url: "   "),
        ]
        #expect(settings.activeFeedSources.map(\.url) == ["https://a.example.com/rss"])
    }

    @Test func decodesSettingsSavedBeforeMultiFeed() throws {
        let legacy = """
        {"refreshSeconds":300,"url":"https://example.com/rss","listDisplay":"list"}
        """
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data(legacy.utf8))
        #expect(settings.feedSources.isEmpty)
        #expect(settings.feedShowsSourceIcons)
        #expect(settings.activeFeedSources.count == 1)
    }

    /// Snapshots cached by an older build have no source fields on their items.
    @Test func decodesFeedItemsSavedBeforeSourceTagging() throws {
        let legacy = """
        {"id":"1","title":"Story","link":"https://www.example.com/a"}
        """
        let item = try JSONDecoder().decode(FeedItem.self, from: Data(legacy.utf8))
        #expect(item.sourceName == nil)
        #expect(item.sourceIcon == nil)
        #expect(item.linkHost == "example.com")
    }
}

@Suite struct FaviconProviderTests {
    @Test func readsLinkTagAttributesInAnyQuotingStyle() {
        #expect(FaviconProvider.attribute("href", in: "<link rel=icon href='/a.png'>") == "/a.png")
        #expect(FaviconProvider.attribute("rel", in: "<link href=\"/a.png\" REL=\"shortcut icon\">")
                == "shortcut icon")
        #expect(FaviconProvider.attribute("sizes", in: "<link rel=icon sizes=32x32 href=/a.png>") == "32x32")
        #expect(FaviconProvider.attribute("href", in: "<link rel=icon>") == nil)
    }

    /// Whatever a site serves — here a 1×1 PNG — comes back as decodable PNG
    /// bytes, and anything that isn't an image is rejected rather than stored.
    @Test func normalizesImagesAndRejectsJunk() throws {
        let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
        let normalized = try #require(FaviconProvider.normalize(onePixelPNG))
        #expect(normalized.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(FaviconProvider.normalize(Data("<!doctype html><html></html>".utf8)) == nil)
    }
}

@Suite struct SettingsCompatibilityTests {
    /// Dashboards saved by the first release (no chart/progress/web-clip
    /// fields) must keep decoding after sync or app updates.
    @Test func decodesLegacySettingsJSON() throws {
        let legacy = """
        {"refreshSeconds":300,"chartStyle":"line","webClipZoom":1,
         "showsSeconds":true,"statusTargets":[],"url":"https://example.com"}
        """
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data(legacy.utf8))
        #expect(settings.url == "https://example.com")
        #expect(settings.progressFormat == .bar)
        #expect(settings.webClipHideSelectors.isEmpty)
        #expect(settings.tableHasHeader)
        #expect(settings.listDisplay == .list)
    }

    @Test func unknownChartStyleFallsBackToLine() throws {
        let futuristic = #"{"chartStyle":"hologram"}"#
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data(futuristic.utf8))
        #expect(settings.chartStyle == .line)
    }

    @Test func emptyObjectDecodes() throws {
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data("{}".utf8))
        #expect(settings.refreshSeconds == 300)
    }
}

@Suite struct WebClipTests {
    @Test func specRoundtripsThroughBridgeMessage() throws {
        let spec = WebClipSpec(url: "https://example.com", width: 800, height: 600,
                               zoom: 1.5, selector: "#main > div.chart",
                               hideSelectors: [".ad", "#cookie-banner"])
        let line = try #require(BridgeMessage.webClipRequest(id: "x", spec: spec).encodedLine())
        let decoded = try #require(BridgeMessage.decodeLine(line.dropLast()))
        guard case .webClipRequest(_, let decodedSpec) = decoded else {
            Issue.record("wrong message type")
            return
        }
        #expect(decodedSpec == spec)
    }

    @Test func legacyRequestWithoutSelectorsDecodes() throws {
        let json = #"{"type":"webclip","id":"a","url":"https://x.com","width":100,"height":100,"zoom":1}"#
        let decoded = try #require(BridgeMessage.decodeLine(Data(json.utf8)))
        guard case .webClipRequest(_, let spec) = decoded else {
            Issue.record("wrong message type")
            return
        }
        #expect(spec.selector == nil)
        #expect(spec.hideSelectors.isEmpty)
    }

    @Test func clipScriptEscapesSelectors() {
        let script = WebClipScripts.clipScript(selector: "#a \"quote\"", hideSelectors: [".x"])
        #expect(script.contains(#"#a \"quote\""#))
        // Hides travel as a JSON array the script turns into CSS at runtime.
        #expect(script.contains(#"[".x"]"#))
        #expect(script.contains("{display:none !important;}"))
    }
}

@Suite struct RendererLogicTests {
    @Test func imageFilterSpecParsing() {
        let steps = SBImageFilter.parse("sepia:70, blur:20 ,grayscale,invert")
        #expect(steps.count == 4)
        #expect(steps[0] == SBImageFilter.Step(name: "sepia", amount: 70))
        #expect(steps[1] == SBImageFilter.Step(name: "blur", amount: 20))
        #expect(steps[2].amount == nil)
    }

    @Test func chartScaleNormalizes() {
        let scale = SBChartCanvas.ChartScale(values: [10, 20, 30], baseline: nil)
        #expect(scale.unit(10) == 0)
        #expect(scale.unit(30) == 1)
        #expect(scale.unit(20) == 0.5)
        let based = SBChartCanvas.ChartScale(values: [10, 20], baseline: 0)
        #expect(based.min == 0)
    }

    @Test func statusTokensColorCorrectly() {
        // Status words resolve against the panel's own style, so a light
        // theme gets readable greens and ambers rather than the dark-panel set.
        let style = SBPanelStyle.board
        #expect(TableContentView.statusColor(for: " Success ", in: style) == style.good)
        #expect(TableContentView.statusColor(for: "DEGRADED", in: style) == style.warn)
        #expect(TableContentView.statusColor(for: "failed", in: style) == style.bad)
        #expect(TableContentView.statusColor(for: "building", in: style) == SBTheme.secondaryAccent)
        #expect(TableContentView.statusColor(for: "hello", in: style) == nil)

        let paper = SBPanelStyle(palette: SBThemeName.paper.palette)
        #expect(TableContentView.statusColor(for: "ok", in: paper) == paper.good)
        #expect(paper.good != style.good)
    }
}

@Suite struct AccessibilitySummaryTests {
    @Test func speaksUnitsAsWords() {
        #expect(AccessibilitySummary.spoken(number: 67, unit: "%") == "67 percent")
        #expect(AccessibilitySummary.spoken(number: 21, unit: "°C") == "21 degrees")
        #expect(AccessibilitySummary.spoken(number: 3.26, unit: "km") == "3.3 km")
        #expect(AccessibilitySummary.spoken(number: 1200, unit: nil) == "1,200")
    }

    @Test func summarizesSeriesWithTrend() {
        let series = SeriesData(points: [SeriesPoint(value: 10), SeriesPoint(value: 20),
                                         SeriesPoint(value: 40)], unit: "%")
        let text = AccessibilitySummary.value(for: .series(series), settings: PanelSettings())
        #expect(text.contains("Latest 40 percent"))
        #expect(text.contains("3 points"))
        #expect(text.contains("trending up"))
    }

    @Test func summarizesServiceOutages() {
        let statuses: [ServiceStatus] = [
            ServiceStatus(name: "API", state: .up),
            ServiceStatus(name: "Web", state: .down),
            ServiceStatus(name: "CDN", state: .degraded),
        ]
        let text = AccessibilitySummary.value(for: .statuses(statuses), settings: PanelSettings())
        #expect(text == "Web down, CDN degraded")

        let allUp = [ServiceStatus(name: "API", state: .up)]
        #expect(AccessibilitySummary.value(for: .statuses(allUp), settings: PanelSettings())
                == "All 1 service up")
    }

    @Test func panelLabelIncludesTitleAndValue() {
        var panel = Panel(kind: .progress, title: "Build",
                          frame: GridRect(x: 0, y: 0, width: 2, height: 1))
        panel.settings.progressTotal = 200
        let label = AccessibilitySummary.panelLabel(panel, snapshot: .number(50, unit: nil))
        #expect(label == "Build. 25 percent")
    }

    @Test func listsReadNaturally() {
        #expect(AccessibilitySummary.list(["a"]) == "a")
        #expect(AccessibilitySummary.list(["a", "b"]) == "a and b")
        #expect(AccessibilitySummary.list(["a", "b", "c"]) == "a, b, and c")
    }
}

@MainActor
@Suite struct UndoTests {
    /// Each test gets its own store file so they don't share on-disk state.
    private func makeStore() -> DashboardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-undo-\(UUID().uuidString).json")
        return DashboardStore(fileURL: url)
    }

    @Test func undoRestoresDeletedPanel() {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        let originalCount = store.dashboards[0].panels.count
        let panelID = store.dashboards[0].panels[0].id

        store.removePanel(id: panelID, from: boardID)
        #expect(store.dashboard(id: boardID)?.panels.count == originalCount - 1)
        #expect(store.canUndo)

        store.undo()
        #expect(store.dashboard(id: boardID)?.panels.count == originalCount)
        #expect(store.dashboard(id: boardID)?.panels.contains { $0.id == panelID } == true)
    }

    @Test func redoReappliesChange() {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        let panelID = store.dashboards[0].panels[0].id

        store.removePanel(id: panelID, from: boardID)
        store.undo()
        #expect(store.canRedo)
        store.redo()
        #expect(store.dashboard(id: boardID)?.panels.contains { $0.id == panelID } == false)
    }

    @Test func undoRestoresDeletedBoard() {
        let store = makeStore()
        store.add(Dashboard(name: "Scratch"))
        let scratchID = store.dashboards.last!.id
        store.delete(id: scratchID)
        #expect(store.dashboard(id: scratchID) == nil)

        store.undo()
        #expect(store.dashboard(id: scratchID)?.name == "Scratch")
    }

    @Test func newEditClearsRedoStack() {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        store.removePanel(id: store.dashboards[0].panels[0].id, from: boardID)
        store.undo()
        #expect(store.canRedo)
        _ = store.addPanel(kind: .text, to: boardID)
        #expect(!store.canRedo)
    }

    @Test func remoteChangesAreNotUndoable() {
        let store = makeStore()
        var board = store.dashboards[0]
        board.name = "Renamed Remotely"
        board.modifiedAt = Date().addingTimeInterval(60)
        store.applyRemote(board)
        // Syncing another device's edit shouldn't land in this device's
        // undo history.
        #expect(!store.canUndo)
    }

    @Test func undoNamesDescribeTheAction() {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        _ = store.addPanel(kind: .weather, to: boardID)
        #expect(store.undoActionName == "Add Weather")
    }
}

@Suite struct PanelPasteboardTests {
    @Test func roundTripsThroughJSON() throws {
        var panel = Panel(kind: .graph, title: "CPU",
                          frame: GridRect(x: 3, y: 2, width: 4, height: 2))
        panel.settings.bridgeKey = "mac.cpu.history"
        panel.settings.chartStyle = .area
        panel.settings.accentColorHex = "#35C4B5"

        let text = try #require(PanelPasteboard.encode(panel))
        let decoded = try #require(PanelPasteboard.decode(text))
        #expect(decoded.kind == .graph)
        #expect(decoded.title == "CPU")
        #expect(decoded.settings.bridgeKey == "mac.cpu.history")
        #expect(decoded.settings.chartStyle == .area)
        #expect(decoded.settings.accentColorHex == "#35C4B5")
    }

    @Test func rejectsUnrelatedText() {
        #expect(PanelPasteboard.decode("hello world") == nil)
        #expect(PanelPasteboard.decode(#"{"some":"json"}"#) == nil)
    }

    @Test func acceptsBarePanelJSON() throws {
        let panel = Panel(kind: .text, title: "Note",
                          frame: GridRect(x: 0, y: 0, width: 2, height: 1))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bare = String(decoding: try encoder.encode(panel), as: UTF8.self)
        #expect(PanelPasteboard.decode(bare)?.title == "Note")
    }
}

@MainActor
@Suite struct PanelCopyTests {
    private func makeStore() -> DashboardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-copy-\(UUID().uuidString).json")
        return DashboardStore(fileURL: url)
    }

    @Test func duplicateGetsNewIDAndFreeSlot() throws {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        let original = store.dashboards[0].panels[0]

        let copy = try #require(store.duplicatePanel(id: original.id, in: boardID))
        #expect(copy.id != original.id)
        #expect(copy.title == original.title)
        #expect(copy.settings == original.settings)
        // It must not land on top of the panel it came from.
        #expect(copy.frame != original.frame)
    }

    @Test func pasteRehomesPanelIntoBoard() throws {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        let before = store.dashboards[0].panels.count

        var incoming = Panel(kind: .clock, title: "Pasted",
                             frame: GridRect(x: 7, y: 3, width: 2, height: 1))
        incoming.settings.timeZoneID = "Asia/Tokyo"

        let inserted = try #require(store.insertPanel(incoming, into: boardID))
        #expect(store.dashboard(id: boardID)?.panels.count == before + 1)
        #expect(inserted.id != incoming.id)
        #expect(inserted.settings.timeZoneID == "Asia/Tokyo")
    }

    @Test func duplicateIsUndoable() throws {
        let store = makeStore()
        let boardID = store.dashboards[0].id
        let before = store.dashboards[0].panels.count
        store.duplicatePanel(id: store.dashboards[0].panels[0].id, in: boardID)
        #expect(store.dashboard(id: boardID)?.panels.count == before + 1)
        store.undo()
        #expect(store.dashboard(id: boardID)?.panels.count == before)
    }
}

@MainActor
@Suite struct BoardCopyTests {
    private func makeStore() -> DashboardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-board-copy-\(UUID().uuidString).json")
        return DashboardStore(fileURL: url)
    }

    @Test func duplicateCopiesPanelsWithFreshIdentities() throws {
        let store = makeStore()
        let original = store.dashboards[0]

        let copy = try #require(store.duplicate(id: original.id))
        #expect(copy.id != original.id)
        #expect(copy.name == "\(original.name) Copy")
        #expect(copy.panels.count == original.panels.count)
        #expect(copy.panels.map(\.title) == original.panels.map(\.title))
        #expect(copy.panels.map(\.settings) == original.panels.map(\.settings))
        #expect(Set(copy.panels.map(\.id)).isDisjoint(with: Set(original.panels.map(\.id))))
        // The original is left exactly as it was.
        #expect(store.dashboard(id: original.id) == original)
    }

    @Test func duplicateLandsAfterTheOriginalAndIsSelected() throws {
        let store = makeStore()
        store.add(Dashboard(name: "Second"))
        let original = store.dashboards[0]

        let copy = try #require(store.duplicate(id: original.id))
        #expect(store.dashboards.map(\.id) == [original.id, copy.id, store.dashboards[2].id])
        #expect(store.selectedDashboardID == copy.id)
    }

    @Test func duplicateRemapsDeviceLayouts() throws {
        let store = makeStore()
        let original = store.dashboards[0]
        let panelID = original.panels[0].id
        let hiddenID = original.panels[1].id
        let frame = GridRect(x: 1, y: 2, width: 2, height: 1)
        store.setPanelFrame(frame, panelID: panelID, in: original.id, on: .tv)
        store.setPanelHidden(true, panelID: hiddenID, in: original.id, on: .tv)

        let copy = try #require(store.duplicate(id: store.dashboards[0].id))
        let layout = try #require(copy.layout(for: .tv))
        let movedCopy = try #require(copy.panels.first { $0.title == original.panels[0].title })
        let hiddenCopy = try #require(copy.panels.first { $0.title == original.panels[1].title })
        #expect(layout.frames[movedCopy.id.uuidString] == frame)
        #expect(layout.hiddenPanelIDs.contains(hiddenCopy.id.uuidString))
        // Nothing keyed by an ID that no longer exists on this board.
        let copiedIDs = Set(copy.panels.map(\.id.uuidString))
        #expect(Set(layout.frames.keys).isSubset(of: copiedIDs))
        #expect(layout.hiddenPanelIDs.isSubset(of: copiedIDs))
    }

    @Test func repeatedDuplicatesGetDistinctNames() throws {
        let store = makeStore()
        let original = store.dashboards[0]
        store.duplicate(id: original.id)
        store.duplicate(id: original.id)
        store.duplicate(id: original.id)
        #expect(store.dashboards.map(\.name) == [original.name,
                                                 "\(original.name) Copy 3",
                                                 "\(original.name) Copy 2",
                                                 "\(original.name) Copy"])
    }

    @Test func duplicateIsUndoable() throws {
        let store = makeStore()
        let before = store.dashboards.count
        let copy = try #require(store.duplicate(id: store.dashboards[0].id))
        #expect(store.dashboards.count == before + 1)
        store.undo()
        #expect(store.dashboards.count == before)
        #expect(store.dashboard(id: copy.id) == nil)
    }
}

@Suite struct SpotlightIdentifierTests {
    @Test func parsesBoardAndPanelIdentifiers() {
        let boardID = UUID()
        let panelID = UUID()
        let boardOnly = SpotlightIndexer.identifier(board: boardID)
        let withPanel = SpotlightIndexer.identifier(board: boardID, panel: panelID)
        #expect(SpotlightIndexer.boardID(fromIdentifier: boardOnly) == boardID)
        #expect(SpotlightIndexer.boardID(fromIdentifier: withPanel) == boardID)
    }

    @Test func rejectsForeignIdentifiers() {
        #expect(SpotlightIndexer.boardID(fromIdentifier: "something/else") == nil)
        #expect(SpotlightIndexer.boardID(fromIdentifier: "board/not-a-uuid") == nil)
    }
}

@Suite struct AdBlockConverterTests {
    @Test func domainAnchoredRule() throws {
        let rule = try #require(AdBlockRuleConverter.convert(line: "||doubleclick.net^"))
        #expect(rule.action.type == "block")
        #expect(rule.trigger.urlFilter.hasPrefix("^[^:]+:(//)?([^/?#]+\\.)?"))
        #expect(rule.trigger.urlFilter.contains("doubleclick\\.net"))
        // Every emitted pattern must actually compile.
        #expect((try? NSRegularExpression(pattern: rule.trigger.urlFilter)) != nil)
    }

    @Test func optionsMapToResourceAndLoadTypes() throws {
        let rule = try #require(
            AdBlockRuleConverter.convert(line: "||ads.example.com^$script,third-party"))
        #expect(rule.trigger.resourceType == ["script"])
        #expect(rule.trigger.loadType == ["third-party"])
    }

    @Test func domainScopingSplitsIncludesAndExcludes() throws {
        let rule = try #require(
            AdBlockRuleConverter.convert(line: "/banner/$domain=example.com|~sub.example.com"))
        #expect(rule.trigger.ifDomain == ["*example.com"])
        #expect(rule.trigger.unlessDomain == ["*sub.example.com"])
    }

    @Test func exceptionsBecomeIgnorePreviousRules() throws {
        let rule = try #require(AdBlockRuleConverter.convert(line: "@@||example.com/ok"))
        #expect(rule.action.type == "ignore-previous-rules")
    }

    @Test func cosmeticRulesBecomeCSSDisplayNone() throws {
        let global = try #require(AdBlockRuleConverter.convert(line: "##.ad-banner"))
        #expect(global.action.type == "css-display-none")
        #expect(global.action.selector == ".ad-banner")
        #expect(global.trigger.ifDomain == nil)

        let scoped = try #require(AdBlockRuleConverter.convert(line: "example.com##.promo"))
        #expect(scoped.trigger.ifDomain == ["*example.com"])
        #expect(scoped.action.selector == ".promo")
    }

    @Test func skipsUnsupportedSyntax() {
        // Extended CSS, cosmetic exceptions, and options WebKit can't express.
        #expect(AdBlockRuleConverter.convert(line: "example.com#@#.ad") == nil)
        #expect(AdBlockRuleConverter.convert(line: "example.com##div:has(> .ad)") == nil)
        #expect(AdBlockRuleConverter.convert(line: "||x.com^$csp=script-src") == nil)
        #expect(AdBlockRuleConverter.convert(line: "||x.com^$popup") == nil)
    }

    @Test func exceptionsSortAfterBlocks() {
        // WebKit applies rules in order, so ignore-previous-rules must come last.
        let list = """
        @@||safe.example.com^
        ||ads.example.com^
        ! a comment
        [Adblock Plus 2.0]
        """
        let rules = AdBlockRuleConverter.convert(filterList: list)
        #expect(rules.count == 2)
        #expect(rules[0].action.type == "block")
        #expect(rules[1].action.type == "ignore-previous-rules")
    }

    @Test func honorsRuleLimit() {
        let list = (0..<50).map { "||ads\($0).example.com^" }.joined(separator: "\n")
        #expect(AdBlockRuleConverter.convert(filterList: list, limit: 10).count == 10)
    }

    @Test func seedListConvertsCleanly() {
        // The built-in offline list must never produce a pattern WebKit rejects.
        let rules = AdBlockRuleConverter.convert(filterList: AdBlockService.seedFilters)
        #expect(rules.count > 40)
        for rule in rules {
            #expect((try? NSRegularExpression(pattern: rule.trigger.urlFilter)) != nil)
        }
        #expect(rules.contains { $0.action.type == "css-display-none" })
    }

    @Test func producesValidJSON() throws {
        let rules = AdBlockRuleConverter.convert(filterList: "||ads.example.com^\n##.ad")
        let json = AdBlockRuleConverter.json(for: rules)
        let parsed = try JSONValue.parse(json)
        let array = try #require(parsed.arrayValue)
        #expect(array.count == 2)
        // WebKit requires these exact key names.
        #expect(array[0]["trigger"]?["url-filter"] != nil)
        #expect(array[1]["action"]?["type"]?.stringValue == "css-display-none")
    }
}

@Suite struct WebClipScriptTests {
    @Test func clipScriptEscapesAndCoversBothConcerns() {
        let script = WebClipScripts.clipScript(selector: "#main .chart",
                                               hideSelectors: [".ad", "#banner"])
        #expect(script.contains("#main .chart"))
        #expect(script.contains(##"[".ad","#banner"]"##))
        #expect(script.contains("{display:none !important;}"))
        // Isolation is done by marking ancestors, not by visibility+scroll.
        #expect(script.contains("data-sb-clip"))
        #expect(script.contains("MutationObserver"))
    }

    @Test func clipScriptWithNoSelectorOnlyHides() {
        let script = WebClipScripts.clipScript(selector: nil, hideSelectors: [".ad"])
        #expect(script.contains(#"[".ad"]"#))
        // An empty selector is what makes the script skip isolation at runtime.
        #expect(script.contains(#"var SEL = "";"#))
    }

    @Test func quotesAreEscapedIntoJavaScript() {
        let script = WebClipScripts.clipScript(selector: "a[title=\"x\"]", hideSelectors: [])
        #expect(script.contains(#"a[title=\"x\"]"#))
    }

    @Test func pickerExposesExpandAndContract() {
        #expect(WebClipScripts.pickerScript.contains("__sbExpand"))
        #expect(WebClipScripts.pickerScript.contains("__sbContract"))
        #expect(WebClipScripts.pickerScript.contains("largestChild"))
    }
}

@Suite struct CanvasSourceTests {
    @Test func shortensNoisyCourseNames() {
        #expect(CanvasSource.shortCourseName("BIOL 101 — Introduction to Biology (Fall 2026)")
                == "BIOL 101")
        #expect(CanvasSource.shortCourseName("MATH 220: Linear Algebra") == "MATH 220")
        #expect(CanvasSource.shortCourseName("Art History") == "Art History")
    }

    @Test func modesCoverTheAskedQuestions() {
        let names = CanvasSource.Mode.allCases.map(\.displayName)
        #expect(names.contains("Due Today"))
        #expect(names.contains("Late / Missing"))
        #expect(names.contains("Current Grades"))
        #expect(names.contains("Today's Classes"))
    }

    @Test func requiresHostAndToken() async {
        var settings = PanelSettings()
        settings.connector = ConnectorConfig()
        let snapshot = await CanvasSource.fetch(settings: settings)
        guard case .error(let message) = snapshot else {
            Issue.record("expected a configuration error")
            return
        }
        #expect(message.contains("Canvas URL"))
    }

    @Test func formatsDatesForSmallPanels() {
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        #expect(!CanvasSource.clock(date).isEmpty)
        #expect(!CanvasSource.relativeDay(date).isEmpty)
        // Planner windows are whole days.
        #expect(CanvasSource.iso(date).count == 10)
    }
}

@Suite struct WebClipCredentialTests {
    @Test func derivesHostFromURL() {
        #expect(WebClipCredentialStore.host(for: "https://school.instructure.com/courses")
                == "school.instructure.com")
        #expect(WebClipCredentialStore.host(for: "HTTPS://Example.COM") == "example.com")
        #expect(WebClipCredentialStore.host(for: "not a url") == nil)
        #expect(WebClipCredentialStore.host(for: nil) == nil)
    }

    @Test func fillScriptEmbedsCredentialsSafely() {
        let script = WebClipLoginScripts.fillScript(username: "a\"b", password: "p'\\w",
                                                    stage: .password)
        // Values must be escaped into JS literals, not concatenated raw.
        #expect(script.contains(#"a\"b"#))
        #expect(script.contains("dispatchEvent"))
        #expect(script.contains("input[type=\"password\"]"))
    }

    @Test func usernameStageOnlyFillsTheUsername() {
        let script = WebClipLoginScripts.fillScript(username: "student", password: "secret",
                                                    stage: .username)
        #expect(script.contains(#""username""#))
        // The password still has to be embedded escaped, but the username
        // branch is what runs — that's what the stage constant selects.
        #expect(script.contains("STAGE === 'password'"))
    }

    /// Single sign-on sends a clip of one host to a different sign-in host on
    /// the same domain — credentials must follow, but no further.
    @Test func credentialsAreSharedAcrossSiblingHostsOnly() {
        #expect(WebClipCredentialStore.domain(for: "learn2.k12.com") == "k12.com")
        #expect(WebClipCredentialStore.domain(for: "login.k12.com") == "k12.com")
        #expect(WebClipCredentialStore.domain(for: "home.k12.com") == "k12.com")
        #expect(WebClipCredentialStore.domain(for: "k12.com") == "k12.com")
        // Different sites must never share a saved password.
        #expect(WebClipCredentialStore.domain(for: "evil.com")
                != WebClipCredentialStore.domain(for: "login.k12.com"))
        #expect(WebClipCredentialStore.domain(for: "k12.com.evil.com") == "evil.com")
    }

    @Test func stageDetectionScriptCoversBothSteps() {
        let script = WebClipLoginScripts.detectStageScript
        #expect(script.contains("'password'"))
        #expect(script.contains("'username'"))
        #expect(script.contains("'none'"))
        // Hidden password fields shouldn't count as a login page.
        #expect(script.contains("visibility"))
    }

    @Test func settingsNeverCarryTheSecret() throws {
        // Passwords live in the Keychain; a panel must not serialize them.
        var settings = PanelSettings()
        settings.webClipAutoLogin = true
        settings.url = "https://example.com"
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("webClipAutoLogin"))
        #expect(!json.lowercased().contains("password"))
    }

    @Test func autoLoginDefaultsOffAndSurvivesOldDashboards() throws {
        let legacy = #"{"refreshSeconds":300,"url":"https://example.com"}"#
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data(legacy.utf8))
        #expect(settings.webClipAutoLogin == false)
        #expect(settings.webClipBlocksAds == true)
    }
}

@Suite struct AssignmentClassificationTests {
    /// Builds a Canvas submission payload with the fields the classifier reads.
    private func submission(state: String, score: Double? = nil, points: Double? = 10,
                            missing: Bool = false, late: Bool = false,
                            excused: Bool = false, dueOffsetDays: Int = 0) -> JSONValue {
        let due = Calendar.current.date(byAdding: .day, value: dueOffsetDays, to: Date())!
        var assignment: [String: JSONValue] = [
            "name": .string("Essay"),
            "html_url": .string("https://learn2.k12.com/courses/1/assignments/2"),
            "due_at": .string(ISO8601DateFormatter().string(from: due)),
            "course_id": .string("1"),
        ]
        if let points { assignment["points_possible"] = .number(points) }
        var object: [String: JSONValue] = [
            "id": .string(UUID().uuidString),
            "workflow_state": .string(state),
            "missing": .number(missing ? 1 : 0),
            "late": .number(late ? 1 : 0),
            "excused": .number(excused ? 1 : 0),
            "assignment": .object(assignment),
        ]
        if let score { object["score"] = .number(score) }
        return .object(object)
    }

    private func classify(_ submissions: [JSONValue]) -> AssignmentDigest {
        var digest = AssignmentDigest()
        for item in submissions {
            AssignmentsSource.classify(item, courseNames: ["1": "History"], into: &digest)
        }
        return digest
    }

    @Test func fullMarksAreHidden() {
        let digest = classify([submission(state: "graded", score: 10, points: 10)])
        #expect(digest.isEmpty)
        #expect(digest.awaitingGrading == 0)
    }

    @Test func gradedBelowFullMarksBecomesRedo() {
        let digest = classify([submission(state: "graded", score: 7, points: 10)])
        #expect(digest.redo.count == 1)
        #expect(digest.redo[0].scoreText == "7/10")
        #expect(digest.redo[0].percent == 70)
        #expect(digest.redo[0].url?.contains("assignments/2") == true)
    }

    @Test func submittedAwaitingGradeIsCountedNotListed() {
        let digest = classify([submission(state: "submitted"),
                               submission(state: "pending_review")])
        #expect(digest.isEmpty)
        #expect(digest.awaitingGrading == 2)
    }

    @Test func missingAndLateBecomeLate() {
        let digest = classify([
            submission(state: "unsubmitted", missing: true, dueOffsetDays: -3),
            submission(state: "unsubmitted", late: true, dueOffsetDays: -1),
        ])
        #expect(digest.late.count == 2)
        #expect(digest.due.isEmpty)
    }

    @Test func unsubmittedDueTodayBecomesDue() {
        let digest = classify([submission(state: "unsubmitted", dueOffsetDays: 0)])
        #expect(digest.due.count == 1)
        #expect(digest.due[0].course == "History")
    }

    @Test func unsubmittedDueLaterIsNotShownYet() {
        let digest = classify([submission(state: "unsubmitted", dueOffsetDays: 5)])
        #expect(digest.isEmpty)
    }

    @Test func excusedWorkIsIgnored() {
        let digest = classify([submission(state: "graded", score: 0, points: 10, excused: true)])
        #expect(digest.isEmpty)
    }

    /// Ungraded-for-points work shouldn't be nagged about forever.
    @Test func gradedWithNoPointsPossibleIsHidden() {
        let digest = classify([submission(state: "graded", score: 0, points: 0)])
        #expect(digest.isEmpty)
    }
}

@Suite("K12 class schedule")
struct K12ScheduleSnapshotTests {
    private func event(_ course: String, minutesFromNow: Double, teacher: String = "",
                       attendance: String = "", url: String? = nil) -> K12OLSSource.ClassEvent {
        let start = Date().addingTimeInterval(minutesFromNow * 60)
        return K12OLSSource.ClassEvent(
            title: course, courseName: course, teacher: teacher,
            start: start, end: start.addingTimeInterval(50 * 60),
            timeText: "1:30 PM", localDay: "", attendance: attendance,
            platform: "", url: url)
    }

    @Test func todaysClassesRenderAsScheduleRowsRatherThanATable() {
        guard case .schedule(let classes) = K12OLSSource.todaySnapshot([
            event("Math 8", minutesFromNow: 120),
            event("Music 3", minutesFromNow: 30)
        ]) else {
            Issue.record("expected a schedule snapshot")
            return
        }
        // Sorted by start, so the panel counts down to the right class.
        #expect(classes.map(\.course) == ["Music 3", "Math 8"])
    }

    @Test func aDayOffIsAnEmptyScheduleNotAnError() {
        guard case .schedule(let classes) = K12OLSSource.todaySnapshot([]) else {
            Issue.record("expected a schedule snapshot")
            return
        }
        #expect(classes.isEmpty)
    }

    @Test func hiddenMeetingsStayOutOfTheList() {
        let classes = K12OLSSource.scheduledClasses([
            event("Math 8", minutesFromNow: 30),
            event("Homeroom", minutesFromNow: 60, attendance: "do-not-display")
        ])
        #expect(classes.map(\.course) == ["Math 8"])
    }

    @Test func theSameMeetingReportedTwiceCollapsesIntoOneRow() {
        let start = Date().addingTimeInterval(30 * 60)
        func copy(teacher: String, attendance: String, url: String?) -> K12OLSSource.ClassEvent {
            K12OLSSource.ClassEvent(
                title: "Math 8", courseName: "Math 8", teacher: teacher,
                start: start, end: start.addingTimeInterval(50 * 60),
                timeText: "1:30 PM", localDay: "", attendance: attendance,
                platform: "", url: url)
        }
        let classes = K12OLSSource.scheduledClasses([
            copy(teacher: "", attendance: "optional", url: nil),
            copy(teacher: "Mallory Smith", attendance: "required",
                 url: "https://learn2.k12.com/class")
        ])
        #expect(classes.count == 1)
        // The duplicate contributes whatever the first copy was missing.
        #expect(classes[0].attendanceRequired)
        #expect(classes[0].teacher == "Mallory Smith")
        #expect(classes[0].url == "https://learn2.k12.com/class")
    }

    @Test func rowsKeepTheirIdentityAcrossRefreshes() {
        let events = [event("Math 8", minutesFromNow: 30)]
        #expect(K12OLSSource.scheduledClasses(events).map(\.id)
                == K12OLSSource.scheduledClasses(events).map(\.id))
    }
}

@Suite struct SchoolPresentationTests {
    @Test func lettersDeriveFromScoreWhenAbsent() {
        #expect(CourseGrade(course: "A", score: 95).displayLetter == "A")
        #expect(CourseGrade(course: "B", score: 85).displayLetter == "B")
        #expect(CourseGrade(course: "C", score: 71).displayLetter == "C")
        #expect(CourseGrade(course: "F", score: 12).displayLetter == "F")
        #expect(CourseGrade(course: "X", score: nil).displayLetter == "—")
        // A published letter always wins.
        #expect(CourseGrade(course: "Y", score: 95, letter: "A-").displayLetter == "A-")
    }

    @Test func countdownReadsNaturally() {
        let now = Date()
        #expect(SchoolStyle.countdown(to: now.addingTimeInterval(-10), from: now) == "now")
        #expect(SchoolStyle.countdown(to: now.addingTimeInterval(30), from: now) == "in <1m")
        #expect(SchoolStyle.countdown(to: now.addingTimeInterval(42 * 60), from: now) == "in 42m")
        #expect(SchoolStyle.countdown(to: now.addingTimeInterval(2 * 3600), from: now) == "in 2h")
        #expect(SchoolStyle.countdown(to: now.addingTimeInterval(2 * 3600 + 15 * 60), from: now)
                == "in 2h 15m")
    }

    @Test func aliasesReplaceCourseNames() {
        var settings = PanelSettings()
        settings.courseAliases = ["AP US History A (Sem 1)": "History"]
        #expect(SchoolStyle.alias("AP US History A (Sem 1)", in: settings) == "History")
        #expect(SchoolStyle.alias("Algebra II", in: settings) == "Algebra II")
        // An empty alias falls back rather than blanking the row.
        settings.courseAliases["Algebra II"] = ""
        #expect(SchoolStyle.alias("Algebra II", in: settings) == "Algebra II")
    }

    @Test func hiddenCoursesDropOutOfTheGradesList() throws {
        let grades = [CourseGrade(course: "Biology", score: 94),
                      CourseGrade(course: "Counselor"),
                      CourseGrade(course: "INDLS")]
        var settings = PanelSettings()
        #expect(settings.visibleGrades(grades).count == 3)

        settings.hiddenCourses = ["Counselor", "INDLS"]
        #expect(settings.visibleGrades(grades).map(\.course) == ["Biology"])

        // The choice has to survive a save, or it un-hides on next launch.
        let restored = try JSONDecoder().decode(
            PanelSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.hiddenCourses == ["Counselor", "INDLS"])
        // Settings written before this build simply hide nothing.
        let legacy = try JSONDecoder().decode(PanelSettings.self, from: Data("{}".utf8))
        #expect(legacy.hiddenCourses.isEmpty)
        #expect(legacy.visibleGrades(grades).count == 3)
    }

    /// Builds one Canvas submission the way the API returns it.
    private func submission(points: Double, state: String, score: Double? = nil,
                            missing: Bool = false, submittedAt: String? = nil,
                            excused: Bool = false, omitted: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = [
            "workflow_state": .string(state),
            "missing": .bool(missing),
            "excused": .bool(excused),
            "assignment": .object(["points_possible": .number(points),
                                   "omit_from_final_grade": .bool(omitted)])
        ]
        fields["score"] = score.map { JSONValue.number($0) } ?? .null
        fields["submitted_at"] = submittedAt.map { JSONValue.string($0) } ?? .null
        return .object(fields)
    }

    @Test func ungradedWorkIsCountedRatherThanScored() {
        let tally = GradesSource.tally([
            submission(points: 10, state: "graded", score: 9, submittedAt: "2026-08-05T00:00:00Z"),
            // Handed in, waiting on the teacher.
            submission(points: 10, state: "submitted", submittedAt: "2026-08-06T00:00:00Z"),
            // The zero a missing-work policy fills in before anyone marks it.
            submission(points: 10, state: "graded", score: 0, missing: true),
            // Not due yet.
            submission(points: 10, state: "unsubmitted")
        ])
        #expect(tally.ungraded == 2)
        // 9/10 — the placeholder zero would otherwise drag this to 45%.
        #expect(tally.score == 90)
    }

    @Test func aRealZeroStillCounts() {
        // Turned in and marked zero is a grade, not a placeholder.
        let tally = GradesSource.tally([
            submission(points: 10, state: "graded", score: 10, submittedAt: "2026-08-05T00:00:00Z"),
            submission(points: 10, state: "graded", score: 0, missing: true,
                       submittedAt: "2026-08-05T00:00:00Z")
        ])
        #expect(tally.ungraded == 0)
        #expect(tally.score == 50)
    }

    @Test func workThatCannotCountIsIgnoredEntirely() {
        let tally = GradesSource.tally([
            submission(points: 10, state: "graded", score: 0, excused: true),
            submission(points: 10, state: "graded", score: 0, omitted: true),
            submission(points: 0, state: "graded", score: 0)
        ])
        #expect(tally == GradesSource.Tally())
        // Nothing marked yet reads as "no score", not as a zero.
        #expect(tally.score == nil)
    }

    @Test func aGradeSavedBeforePendingCountsStillLoads() throws {
        let legacy = Data(#"{"id":"1","course":"Geography","score":92}"#.utf8)
        let grade = try JSONDecoder().decode(CourseGrade.self, from: legacy)
        #expect(grade.ungradedCount == 0)
        #expect(grade.score == 92)
    }

    @Test func scheduleKnowsLiveAndFinished() {
        let now = Date()
        let live = ScheduledClass(course: "Bio", start: now.addingTimeInterval(-60),
                                  end: now.addingTimeInterval(600))
        let done = ScheduledClass(course: "Bio", start: now.addingTimeInterval(-7200),
                                  end: now.addingTimeInterval(-3600))
        #expect(live.isLive(at: now))
        #expect(!live.hasEnded(at: now))
        #expect(done.hasEnded(at: now))
        #expect(!done.isLive(at: now))
    }

    @Test func newSnapshotsSurviveEncoding() throws {
        let snapshots: [DataSnapshot] = [
            .grades([CourseGrade(course: "Bio", score: 91.5, letter: "A-")]),
            .schedule([ScheduledClass(course: "Bio", timeText: "9:30 AM",
                                      attendanceRequired: true)]),
            .assignments(AssignmentDigest(
                due: [AssignmentItem(title: "Essay", course: "Bio", state: .dueToday)],
                redo: [AssignmentItem(title: "Quiz", course: "Bio", state: .redo,
                                      score: 7, pointsPossible: 10)],
                awaitingGrading: 2)),
        ]
        for snapshot in snapshots {
            let data = try JSONEncoder().encode(snapshot)
            #expect(try JSONDecoder().decode(DataSnapshot.self, from: data) == snapshot)
        }
    }
}

@Suite struct ConnectorTests {
    @Test func logParserHandlesCombinedFormat() {
        let log = """
        203.0.113.9 - - [05/Aug/2026:10:00:01 +0000] "GET /index.html HTTP/1.1" 200 5120 "-" "Mozilla"
        203.0.113.9 - - [05/Aug/2026:10:01:20 +0000] "GET /api/data?page=2 HTTP/1.1" 200 128
        198.51.100.4 - - [05/Aug/2026:11:15:00 +0000] "POST /login HTTP/1.1" 401 64
        junk line that should not match
        198.51.100.4 - - [05/Aug/2026:11:16:00 +0000] "GET /missing HTTP/1.1" 404 0
        """
        let entries = LogAnalyticsSource.parse(log)
        #expect(entries.count == 4)
        #expect(entries[1].path == "/api/data")
        #expect(entries[2].status == 401)
        #expect(entries[0].date != nil)
    }

    @Test func githubRunStatusMapping() {
        #expect(GitHubSource.normalizedRunStatus(conclusion: "success", status: nil) == "success")
        #expect(GitHubSource.normalizedRunStatus(conclusion: "failure", status: nil) == "failed")
        #expect(GitHubSource.normalizedRunStatus(conclusion: nil, status: "in_progress") == "running")
        #expect(GitHubSource.normalizedRunStatus(conclusion: nil, status: "queued") == "pending")
    }

    @Test func appStoreConnectJWTShape() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try AppStoreConnectSource.jwt(keyID: "ABC123", issuerID: "issuer-id",
                                                privateKeyPEM: key.pemRepresentation)
        let segments = jwt.split(separator: ".")
        #expect(segments.count == 3)
        func decode(_ segment: Substring) -> JSONValue? {
            var base64 = segment.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return Data(base64Encoded: base64).flatMap { try? JSONValue.parse($0) }
        }
        let header = try #require(decode(segments[0]))
        let payload = try #require(decode(segments[1]))
        #expect(header["alg"]?.stringValue == "ES256")
        #expect(header["kid"]?.stringValue == "ABC123")
        #expect(payload["aud"]?.stringValue == "appstoreconnect-v1")
        #expect(payload["iss"]?.stringValue == "issuer-id")
    }

    @Test func supabaseRowShaping() throws {
        var settings = PanelSettings()
        settings.unit = "users"
        // Single scalar → number
        let single = try JSONValue.parse(#"[{"count": 42}]"#)
        #expect(SupabaseSource.snapshot(fromRows: single, settings: settings)
                == .number(42, unit: "users"))
        // Label + value pairs → series
        let pairs = try JSONValue.parse(#"[{"day":"Mon","total":5},{"day":"Tue","total":8}]"#)
        if case .series(let series) = SupabaseSource.snapshot(fromRows: pairs, settings: settings) {
            #expect(series.points.map(\.value) == [5, 8])
        } else {
            Issue.record("expected series")
        }
        // Wide rows → table
        let wide = try JSONValue.parse(#"[{"id":1,"name":"a","state":"ok"}]"#)
        if case .table(let table) = SupabaseSource.snapshot(fromRows: wide, settings: settings) {
            #expect(table.columns.count == 3)
        } else {
            Issue.record("expected table")
        }
    }
}

@Suite struct BridgeProtocolTests {
    @Test func messageRoundtrip() throws {
        let record = SnapshotRecord(snapshot: .number(7, unit: "req/s"))
        let message = BridgeMessage.snapshot(key: "bridge/x", record: record)
        let line = try #require(message.encodedLine())
        let decoded = try #require(BridgeMessage.decodeLine(line.dropLast()))
        if case .snapshot(let key, let decodedRecord) = decoded {
            #expect(key == "bridge/x")
            #expect(decodedRecord.snapshot == record.snapshot)
        } else {
            Issue.record("wrong message type")
        }
    }

    @Test func pushRequestDecoding() throws {
        let json = #"{"key":"cpu","number":42.5,"unit":"%","history":60}"#
        let push = try JSONDecoder().decode(BridgePushRequest.self, from: Data(json.utf8))
        #expect(push.key == "cpu")
        #expect(push.primarySnapshot() == .number(42.5, unit: "%"))
    }

    @Test func csvParsing() {
        let table = WebQuerySource.csv("name,count\n\"a, inc\",3\nb,4")
        #expect(table.columns == ["name", "count"])
        #expect(table.rows == [["a, inc", "3"], ["b", "4"]])
    }
}

@Suite("Watch layout")
struct WatchLayoutTests {
    private func panel(_ kind: PanelKind, width: Int) -> Panel {
        Panel(kind: kind,
              title: "\(kind)",
              frame: GridRect(x: 0, y: 0, width: width, height: 2))
    }

    @Test func screenWidthPicksTheRightClass() {
        // 41 mm reports 176 pt, 45 mm reports 198 pt.
        #expect(WatchLayout.width(forScreenWidth: 176) == .compact)
        #expect(WatchLayout.width(forScreenWidth: 198) == .regular)
    }

    @Test func compactWatchesGetOnePanelPerRow() {
        let panels = [panel(.clock, width: 1), panel(.progress, width: 1)]
        let rows = WatchLayout.rows(for: panels, boardColumns: 6, width: .compact)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.count == 1 })
    }

    @Test func smallPanelsPairUpOnWiderWatches() {
        let panels = [panel(.clock, width: 1), panel(.progress, width: 1)]
        let rows = WatchLayout.rows(for: panels, boardColumns: 6, width: .regular)
        #expect(rows.count == 1)
        #expect(rows[0].count == 2)
    }

    @Test func detailHeavyPanelsAlwaysTakeAFullRow() {
        // A graph is unreadable at half width even on the largest watch.
        let panels = [panel(.clock, width: 1), panel(.graph, width: 1), panel(.progress, width: 1)]
        let rows = WatchLayout.rows(for: panels, boardColumns: 6, width: .regular)
        #expect(rows.map(\.count) == [1, 1, 1])
        #expect(rows[1][0].kind == .graph)
    }

    @Test func panelsWideOnTheBoardStayWideOnTheWatch() {
        // Occupies more than half the board's columns, so it keeps its own row.
        let panels = [panel(.clock, width: 4), panel(.progress, width: 1), panel(.text, width: 1)]
        let rows = WatchLayout.rows(for: panels, boardColumns: 6, width: .regular)
        #expect(rows.map(\.count) == [1, 2])
    }

    @Test func aDanglingPanelStillGetsARow() {
        let panels = [panel(.clock, width: 1), panel(.progress, width: 1), panel(.text, width: 1)]
        let rows = WatchLayout.rows(for: panels, boardColumns: 6, width: .regular)
        #expect(rows.map(\.count) == [2, 1])
        #expect(rows.flatMap { $0 }.count == panels.count)   // nothing dropped
    }

    @Test func tileHeightStaysWithinReadableBounds() {
        for width in stride(from: 120.0, through: 220.0, by: 10.0) {
            for full in [true, false] {
                let h = WatchLayout.tileHeight(forScreenWidth: width, isFullWidth: full)
                #expect(h >= 56 && h <= 132)
            }
        }
    }
}

@Suite struct DeviceLayoutTests {
    private func board() -> Dashboard {
        var board = Dashboard(name: "Test", grid: BoardGrid(columns: 4, rows: 2))
        board.panels = [
            Panel(kind: .clock, title: "Clock", frame: GridRect(x: 0, y: 0, width: 2, height: 1)),
            Panel(kind: .text, title: "Note", frame: GridRect(x: 2, y: 0, width: 2, height: 1)),
        ]
        return board
    }

    @Test func devicesWithoutOverridesShareOneLayout() {
        let board = board()
        for device in SBDeviceClass.allCases {
            #expect(board.hasCustomLayout(for: device) == false)
            #expect(board.panels(for: device).map(\.frame) == board.panels.map(\.frame))
            #expect(board.grid(for: device).columns == board.grid.columns)
        }
    }

    @Test func movingAPanelOnOneDeviceLeavesTheOthersAlone() {
        var board = board()
        let clock = board.panels[0]
        board.setFrame(GridRect(x: 0, y: 1, width: 4, height: 1), for: clock.id, on: .tv)

        #expect(board.frame(for: clock, device: .tv) == GridRect(x: 0, y: 1, width: 4, height: 1))
        #expect(board.frame(for: clock, device: .mac) == clock.frame)
        #expect(board.panels[0].frame == clock.frame)   // the shared layout is untouched
        #expect(board.hasCustomLayout(for: .mac) == false)
    }

    @Test func hidingAPanelRemovesItFromThatDeviceOnly() {
        var board = board()
        let note = board.panels[1]
        board.setHidden(true, for: note.id, on: .phone)

        #expect(board.panels(for: .phone).count == 1)
        #expect(board.panels(for: .tv).count == 2)
        #expect(board.isHidden(note.id, on: .phone))
        #expect(board.isHidden(note.id, on: .tv) == false)
    }

    /// The bug this guards against: a panel sitting below the stored row count
    /// would be laid out past the bottom of the screen and never seen.
    @Test func gridAlwaysCoversEveryPanelItShows() {
        var board = board()
        board.panels.append(Panel(kind: .text, title: "Low",
                                  frame: GridRect(x: 0, y: 6, width: 2, height: 2)))
        #expect(board.grid.rows == 2)              // stored grid is too short…
        #expect(board.grid(for: .tv).rows == 8)    // …but nothing is cut off
    }

    @Test func resettingGoesBackToTheSharedLayout() {
        var board = board()
        let clock = board.panels[0]
        board.setFrame(GridRect(x: 3, y: 1, width: 1, height: 1), for: clock.id, on: .tv)
        #expect(board.hasCustomLayout(for: .tv))

        board.resetLayout(for: .tv)
        #expect(board.hasCustomLayout(for: .tv) == false)
        #expect(board.frame(for: clock, device: .tv) == clock.frame)
    }

    @Test func customizingStartsFromWhatTheDeviceShowsToday() {
        var board = board()
        board.beginCustomLayout(for: .tv)
        #expect(board.panels(for: .tv).map(\.frame) == board.panels.map(\.frame))
        #expect(board.grid(for: .tv) == board.grid)
    }

    @Test func autoArrangeKeepsEveryVisiblePanelInsideTheGrid() {
        var board = board()
        board.panels.append(Panel(kind: .graph, title: "Wide",
                                  frame: GridRect(x: 0, y: 1, width: 12, height: 2)))
        board.setHidden(true, for: board.panels[1].id, on: .phone)
        board.autoArrange(for: .phone)

        let grid = board.grid(for: .phone)
        let shown = board.panels(for: .phone)
        #expect(shown.count == 2)                                  // the hidden one stays hidden
        for panel in shown {
            #expect(panel.frame.x + panel.frame.width <= grid.columns)
            #expect(panel.frame.y + panel.frame.height <= grid.rows)
        }
    }

    @Test func copyingALayoutMirrorsTheSource() {
        var board = board()
        let clock = board.panels[0]
        board.setFrame(GridRect(x: 2, y: 1, width: 2, height: 1), for: clock.id, on: .tv)
        board.copyLayout(from: .tv, to: .pad)
        #expect(board.frame(for: clock, device: .pad) == board.frame(for: clock, device: .tv))

        // Copying from a device that follows the shared layout clears the target.
        board.copyLayout(from: .mac, to: .pad)
        #expect(board.hasCustomLayout(for: .pad) == false)
    }

    /// Boards written before per-device layouts existed are already in iCloud;
    /// they must still decode.
    @Test func boardsSavedBeforeDeviceLayoutsStillDecode() throws {
        let legacy = """
        {
          "id": "8B2A5E5E-0F9E-4F1E-9E0E-9B0B1C2D3E4F",
          "name": "Legacy",
          "grid": {"columns": 4, "rows": 2},
          "panels": [],
          "createdAt": "2026-01-01T00:00:00Z",
          "modifiedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = try decoder.decode(Dashboard.self, from: Data(legacy.utf8))
        #expect(board.name == "Legacy")
        #expect(board.deviceLayouts.isEmpty)
        #expect(board.hasCustomLayout(for: .tv) == false)
    }

    @Test func deviceLayoutsSurviveARoundtrip() throws {
        var original = board()
        original.setFrame(GridRect(x: 1, y: 1, width: 2, height: 1),
                          for: original.panels[0].id, on: .tv)
        original.setHidden(true, for: original.panels[1].id, on: .tv)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Dashboard.self, from: try encoder.encode(original))

        #expect(decoded.layout(for: .tv) == original.layout(for: .tv))
        #expect(decoded.panels(for: .tv).count == 1)
    }
}

@Suite @MainActor struct DisplayOnlyDeviceTests {
    /// A store standing in for an Apple TV or Watch: a screen that shows
    /// boards but never authors them.
    private func displayOnlyStore(at url: URL) -> DashboardStore {
        DashboardStore(fileURL: url, authorsBoards: false)
    }

    private func tempURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dashboards.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return url
    }

    /// The bug behind "my Apple TV shows Clock/Weather/Launch/News, none of
    /// which are on my Mac": the TV made its own starter board, showed it, and
    /// never switched away from it when the real boards synced down.
    @Test func aLeftoverLocalBoardIsDroppedAndTheSyncedOneIsShown() throws {
        let url = try tempURL()
        // An older build's starter board, saved locally and never in iCloud.
        SBStorage.write([Dashboard.starter()], to: url)

        let store = displayOnlyStore(at: url)
        #expect(store.dashboards.isEmpty)
        #expect(store.selectedDashboardID == nil)

        let real = Dashboard(name: "Operations")
        store.applyRemote(real)
        #expect(store.dashboards.map(\.name) == ["Operations"])
        #expect(store.selectedDashboardID == real.id)   // and it's what's on screen
    }

    /// The same file on a Mac keeps its board: only display-only devices treat
    /// the local file as a cache.
    @Test func aMacKeepsItsOwnBoards() throws {
        let url = try tempURL()
        SBStorage.write([Dashboard.starter()], to: url)
        let store = DashboardStore(fileURL: url, authorsBoards: true)
        #expect(store.dashboards.count == 1)
    }

    /// Boards that did come from iCloud must survive a relaunch, so the TV
    /// still shows something while it's offline.
    @Test func syncedBoardsAreKeptAcrossLaunches() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        let synced = Dashboard(name: "Operations")
        store.applyRemote(synced)
        store.saveNow()

        let relaunched = displayOnlyStore(at: url)
        #expect(relaunched.dashboards.map(\.id) == [synced.id])
        #expect(relaunched.selectedDashboardID == synced.id)
    }

    @Test func aBoardDeletedInICloudIsForgotten() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        let synced = Dashboard(name: "Operations")
        store.applyRemote(synced)
        store.applyRemoteDeletion(id: synced.id)
        store.saveNow()

        let relaunched = displayOnlyStore(at: url)
        #expect(relaunched.dashboards.isEmpty)
    }

    /// An edit made on the Mac must replace what the TV is already showing,
    /// rather than arriving as a second board.
    @Test func anEditedBoardReplacesTheCopyOnScreen() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        var board = Dashboard(name: "Operations")
        board.panels = [Panel(kind: .clock, title: "Clock",
                              frame: GridRect(x: 0, y: 0, width: 2, height: 1))]
        store.applyRemote(board)

        var edited = board
        edited.panels.append(Panel(kind: .text, title: "Grades",
                                   frame: GridRect(x: 2, y: 0, width: 2, height: 1)))
        edited.modifiedAt = board.modifiedAt.addingTimeInterval(60)
        store.applyRemote(edited)

        #expect(store.dashboards.count == 1)
        #expect(store.dashboards[0].panels.map(\.title) == ["Clock", "Grades"])
    }

    // MARK: - Boards over the Mac bridge

    /// The whole point of bridge delivery: an Apple TV that iCloud never
    /// reaches still gets its boards from the Mac on the same network.
    @Test func boardsArriveFromTheBridgeWithoutICloud() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        let board = Dashboard(name: "Operations")
        store.applyBridgeBoards([board])

        #expect(store.dashboards.map(\.name) == ["Operations"])
        #expect(store.selectedDashboardID == board.id)
    }

    @Test func bridgeBoardsSurviveARelaunch() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        let board = Dashboard(name: "Operations")
        store.applyBridgeBoards([board])
        store.saveNow()

        let relaunched = displayOnlyStore(at: url)
        #expect(relaunched.dashboards.map(\.id) == [board.id])
    }

    /// The Mac sends its whole set, so a board deleted there goes away here.
    @Test func aBoardTheMacNoLongerHasIsDropped() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        let kept = Dashboard(name: "Operations")
        let removed = Dashboard(name: "Scratch")
        store.applyBridgeBoards([kept, removed])
        store.applyBridgeBoards([kept])

        #expect(store.dashboards.map(\.name) == ["Operations"])
    }

    /// But the Mac's list is not the last word on boards it has never seen —
    /// one made on an iPhone and delivered by iCloud must not vanish just
    /// because a Mac on the network hasn't synced it yet.
    @Test func aBridgeUpdateLeavesICloudBoardsAlone() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        let fromPhone = Dashboard(name: "From iPhone")
        store.applyRemote(fromPhone)
        store.applyBridgeBoards([Dashboard(name: "From Mac")])

        #expect(store.dashboards.map(\.name).sorted() == ["From Mac", "From iPhone"])
    }

    /// Last-writer-wins, same as iCloud: a stale copy from a Mac that has been
    /// asleep must not undo an edit that already arrived.
    @Test func anOlderBridgeCopyDoesNotOverwriteANewerBoard() throws {
        let url = try tempURL()
        let store = displayOnlyStore(at: url)
        var board = Dashboard(name: "Operations")
        board.modifiedAt = Date()
        store.applyRemote(board)

        var stale = board
        stale.name = "Old Name"
        stale.modifiedAt = board.modifiedAt.addingTimeInterval(-3600)
        store.applyBridgeBoards([stale])

        #expect(store.dashboards.map(\.name) == ["Operations"])
    }

    /// A Mac, iPad or iPhone authors its own boards. A bridge on the network
    /// must never be able to replace them.
    @Test func anAuthoringDeviceIgnoresBridgeBoards() throws {
        let url = try tempURL()
        let store = DashboardStore(fileURL: url, authorsBoards: true)
        let before = store.dashboards.map(\.id)
        store.applyBridgeBoards([Dashboard(name: "From Some Other Mac")])

        #expect(store.dashboards.map(\.id) == before)
    }

    @Test func boardsRoundtripThroughTheWireProtocol() throws {
        var board = Dashboard(name: "Operations")
        board.panels = [Panel(kind: .clock, title: "Clock",
                              frame: GridRect(x: 0, y: 0, width: 2, height: 1))]
        let line = try #require(BridgeMessage.boards([board]).encodedLine())
        let decoded = try #require(BridgeMessage.decodeLine(line.dropLast()))
        guard case .boards(let boards) = decoded else {
            Issue.record("wrong message type")
            return
        }
        #expect(boards.map(\.id) == [board.id])
        #expect(boards[0].panels.map(\.title) == ["Clock"])
    }
}

@Suite("K12 session cookies")
struct SessionCookieJarTests {
    private func cookie(_ name: String, _ value: String = "v",
                        domain: String = "home.k12.com", path: String = "/",
                        secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private let api = URL(string: "https://home.k12.com/api/canvas/events/classes")!

    /// The bug this whole jar exists for. `HTTPCookieStorage()` looks like a
    /// private cookie store and is not: it drops every `setCookie` on the
    /// floor and reads back `nil`. The K12 sheet counted the cookies it handed
    /// over, so it reported a successful sign-in, saved an empty list to the
    /// Keychain, and then sent every request with no session at all — which
    /// came back 401 as "your K12 sign-in expired", forever.
    @Test func aDetachedHTTPCookieStorageKeepsNothing() {
        let storage = HTTPCookieStorage()
        storage.setCookie(cookie("SESSION"))
        #expect(storage.cookies(for: api)?.isEmpty != false)

        var jar = SessionCookieJar()
        jar.absorb([cookie("SESSION")])
        #expect(jar.matching(api).map(\.name) == ["SESSION"])
        #expect(jar.header(for: api)?.contains("SESSION=v") == true)
    }

    @Test func cookiesAreSentOnlyToHostsAndPathsThatMatch() {
        var jar = SessionCookieJar()
        jar.absorb([
            cookie("wide", domain: ".k12.com"),
            cookie("exact", domain: "home.k12.com"),
            cookie("elsewhere", domain: "example.com"),
            cookie("scoped", domain: "home.k12.com", path: "/api"),
            cookie("deeper", domain: "home.k12.com", path: "/api/other"),
        ])
        #expect(jar.matching(api).map(\.name).sorted() == ["exact", "scoped", "wide"])
    }

    /// "/api" must cover "/api/v1" but not "/apixyz".
    @Test func pathPrefixesStopAtASegmentBoundary() {
        #expect(SessionCookieJar.pathMatches(requestPath: "/api/v1", cookiePath: "/api"))
        #expect(!SessionCookieJar.pathMatches(requestPath: "/apixyz", cookiePath: "/api"))
        #expect(SessionCookieJar.pathMatches(requestPath: "/anything", cookiePath: "/"))
    }

    @Test func secureCookiesNeverTravelOverPlainHTTP() {
        var jar = SessionCookieJar()
        jar.absorb([cookie("SESSION", secure: true)])
        #expect(jar.matching(URL(string: "http://home.k12.com/api")!).isEmpty)
    }

    @Test func expiredCookiesAreNeitherSentNorKept() {
        var jar = SessionCookieJar()
        jar.absorb([cookie("stale", expires: Date().addingTimeInterval(-60))])
        #expect(jar.isEmpty)

        jar.absorb([cookie("live", expires: Date().addingTimeInterval(3600))])
        #expect(jar.matching(api).map(\.name) == ["live"])
    }

    /// A refreshed session cookie has to replace the old one, not sit beside it.
    @Test func aRefreshedCookieReplacesTheOneItSupersedes() {
        var jar = SessionCookieJar()
        let stored = jar.absorb([cookie("SESSION", "first")])
        let repeated = jar.absorb([cookie("SESSION", "first")])
        let refreshed = jar.absorb([cookie("SESSION", "second")])
        #expect(stored)
        #expect(!repeated)   // unchanged, so no Keychain write
        #expect(refreshed)
        #expect(jar.cookies.count == 1)
        #expect(jar.header(for: api) == "SESSION=second")
    }

    /// Expiry used to be written out as an ISO string, which `HTTPCookie`
    /// silently refuses on the way back in.
    @Test func persistenceKeepsDomainPathSecureAndExpiry() {
        let expires = Date().addingTimeInterval(3600)
        var jar = SessionCookieJar()
        jar.absorb([cookie("SESSION", "abc", path: "/api", expires: expires)])

        let restored = SessionCookieJar.restored(from: jar.persistable)
        let cookie = try! #require(restored.cookies.first)
        #expect(cookie.name == "SESSION")
        #expect(cookie.value == "abc")
        #expect(cookie.domain == "home.k12.com")
        #expect(cookie.path == "/api")
        #expect(cookie.isSecure)
        #expect(abs((cookie.expiresDate ?? .distantPast).timeIntervalSince(expires)) < 1)
        #expect(restored.matching(api).map(\.name) == ["SESSION"])
    }

    @Test func aCookieThatExpiredWhileTheAppWasClosedIsNotRestored() {
        var jar = SessionCookieJar()
        jar.absorb([cookie("SESSION", expires: Date().addingTimeInterval(60))])
        let entries = jar.persistable
        let later = Date().addingTimeInterval(120)
        #expect(SessionCookieJar.restored(from: entries, now: later).isEmpty)
    }

    /// The sign-in sheet adopts by registrable domain, so the SSO hop through
    /// security-gateway.k12.com is kept and the rest of the browser is not.
    @Test func adoptionScopeCoversTheWholePortalDomain() {
        #expect(SessionCookieJar.registrableDomain(of: "https://home.k12.com") == "k12.com")
        #expect(SessionCookieJar.registrableDomain(of: "learn2.k12.com") == "k12.com")
        #expect(SessionCookieJar.registrableDomain(of: "school.instructure.com") == "instructure.com")
        #expect(SessionCookieJar.domainMatches(host: "security-gateway.k12.com",
                                               cookieDomain: "k12.com"))
        #expect(!SessionCookieJar.domainMatches(host: "notk12.com", cookieDomain: "k12.com"))
    }
}

@Suite("Shared Canvas credentials")
@MainActor struct CanvasCredentialsTests {
    private func canvasPanel(_ kind: PanelKind, host: String? = nil,
                             token: String? = nil) -> Panel {
        var panel = Panel(kind: kind, title: kind.displayName,
                          frame: GridRect(x: 0, y: 0, width: 4, height: 2))
        var connector = ConnectorConfig()
        connector.projectURL = host
        connector.token = token
        panel.settings.connector = connector
        return panel
    }

    private func store(with panels: [Panel]) throws -> DashboardStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-canvas-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dashboards.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let store = DashboardStore(fileURL: url, authorsBoards: true)
        // Drop the starter board, so the board under test is dashboards[0].
        for existing in store.dashboards { store.delete(id: existing.id) }
        var board = Dashboard(name: "School")
        board.panels = panels
        store.add(board)
        return store
    }

    @Test func onlyCanvasBackedPanelsShareCredentials() {
        #expect(PanelKind.canvas.usesCanvasCredentials)
        #expect(PanelKind.grades.usesCanvasCredentials)
        #expect(PanelKind.assignments.usesCanvasCredentials)
        // The schedule panels sign in through the portal, not a token.
        #expect(!PanelKind.schedule.usesCanvasCredentials)
        #expect(!PanelKind.k12schedule.usesCanvasCredentials)
        #expect(!PanelKind.github.usesCanvasCredentials)
    }

    /// Signing in on one panel signs in the rest — the whole point.
    @Test func credentialsReachEveryOtherCanvasPanel() throws {
        let signedIn = canvasPanel(.grades, host: "learn2.k12.com", token: "tok-1")
        let store = try store(with: [signedIn,
                                     canvasPanel(.assignments),
                                     canvasPanel(.canvas),
                                     Panel(kind: .clock, title: "Clock",
                                           frame: GridRect(x: 0, y: 2, width: 2, height: 1))])

        let updated = store.applyCanvasCredentials(host: "learn2.k12.com", token: "tok-1",
                                                   excluding: signedIn.id)
        #expect(updated == 2)
        for panel in store.dashboards[0].panels where panel.kind.usesCanvasCredentials {
            #expect(panel.settings.connector?.projectURL == "learn2.k12.com")
            #expect(panel.settings.connector?.token == "tok-1")
        }
        // The clock is not a Canvas panel and must be left entirely alone.
        let clock = store.dashboards[0].panels.first { $0.kind == .clock }
        #expect(clock?.settings.connector == nil)
    }

    /// A rotated token used to fix one panel and silently break the others.
    @Test func rotatingATokenUpdatesPanelsThatHadTheOldOne() throws {
        let edited = canvasPanel(.grades, host: "learn2.k12.com", token: "tok-2")
        let store = try store(with: [edited,
                                     canvasPanel(.assignments, host: "learn2.k12.com",
                                                 token: "tok-1")])
        #expect(store.applyCanvasCredentials(host: "learn2.k12.com", token: "tok-2",
                                             excluding: edited.id) == 1)
        #expect(store.dashboards[0].panels[1].settings.connector?.token == "tok-2")
    }

    @Test func aNoOpSweepChangesNothingAndCostsNoUndoStep() throws {
        let panel = canvasPanel(.grades, host: "learn2.k12.com", token: "tok-1")
        let store = try store(with: [panel,
                                     canvasPanel(.canvas, host: "learn2.k12.com",
                                                 token: "tok-1")])
        let undoBefore = store.canUndo
        #expect(store.applyCanvasCredentials(host: "learn2.k12.com", token: "tok-1",
                                             excluding: panel.id) == 0)
        #expect(store.canUndo == undoBefore)
    }

    @Test func defaultsFillOnlyTheFieldsAPanelIsMissing() {
        let shared = CanvasCredentials.Snapshot(host: "learn2.k12.com", token: "tok-1")

        var empty = ConnectorConfig()
        CanvasCredentials.fill(&empty, from: shared)
        #expect(empty.projectURL == "learn2.k12.com")
        #expect(empty.token == "tok-1")

        // A panel deliberately pointed at another school keeps its own values.
        var other = ConnectorConfig()
        other.projectURL = "other.instructure.com"
        other.token = "tok-other"
        CanvasCredentials.fill(&other, from: shared)
        #expect(other.projectURL == "other.instructure.com")
        #expect(other.token == "tok-other")

        // Whitespace and a stray trailing slash are not a configured value.
        var blank = ConnectorConfig()
        blank.projectURL = "  "
        CanvasCredentials.fill(&blank, from: shared)
        #expect(blank.projectURL == "learn2.k12.com")
        #expect(CanvasCredentials.normalized("https://learn2.k12.com/") == "https://learn2.k12.com")
        #expect(CanvasCredentials.normalized("") == nil)
    }
}

// MARK: - Tessie (Tesla)

@Suite struct TessieParsingTests {
    /// A trimmed copy of Tessie's documented `/{vin}/state` response, with the
    /// car in drive and navigating.
    static let drivingState = try! JSONValue.parse("""
    {
      "vin": "5YJXCAE43LF123456",
      "display_name": "Roadrunner",
      "state": "online",
      "drive_state": {
        "power": 42, "speed": 63, "heading": 194,
        "latitude": 37.4929681, "longitude": -121.9453489,
        "timestamp": 1643590652755, "shift_state": "D",
        "active_route_destination": "Empire State Building",
        "active_route_energy_at_arrival": 41,
        "active_route_latitude": 40.7484, "active_route_longitude": -73.9857,
        "active_route_miles_to_arrival": 4.12,
        "active_route_minutes_to_arrival": 5.43,
        "active_route_traffic_minutes_delay": 12
      },
      "charge_state": {
        "battery_level": 89, "usable_battery_level": 88, "battery_range": 269.01,
        "charge_limit_soc": 90, "charging_state": "Disconnected",
        "charger_power": 0, "minutes_to_full_charge": 0
      },
      "climate_state": {
        "inside_temp": 24.3, "outside_temp": 18.5, "is_climate_on": true,
        "is_preconditioning": false
      },
      "vehicle_state": {
        "df": 0, "dr": 0, "pf": 1, "pr": 0, "ft": 0, "rt": 0,
        "fd_window": 0, "fp_window": 0, "rd_window": 1, "rp_window": 0,
        "locked": true, "odometer": 12345.6, "sentry_mode": false,
        "sentry_mode_available": true, "is_user_present": true,
        "car_version": "2022.4 fae2af490933",
        "smart_summon_available": true,
        "software_update": {"status": "available", "version": "2022.8", "download_perc": 0},
        "speed_limit_mode": {"active": true, "current_limit_mph": 84},
        "tpms_pressure_fl": 2.9, "tpms_pressure_fr": 2.85,
        "tpms_pressure_rl": 2.95, "tpms_pressure_rr": 2.9
      },
      "vehicle_config": {"driver_assist": "TeslaAP3"},
      "gui_settings": {"gui_distance_units": "mi/hr", "gui_temperature_units": "F"}
    }
    """)

    var vehicle: TessieVehicle {
        TessieSource.parse(state: Self.drivingState, fallbackVIN: "FALLBACK")
    }

    @Test func flattensTheStateResponse() {
        let vehicle = vehicle
        #expect(vehicle.vin == "5YJXCAE43LF123456")
        #expect(vehicle.name == "Roadrunner")
        #expect(vehicle.connection == .online)
        #expect(vehicle.drive.gear == .drive)
        #expect(vehicle.drive.speedMPH == 63)
        #expect(vehicle.drive.odometerMiles == 12345.6)
        #expect(vehicle.battery.level == 89)
        #expect(vehicle.security.isLocked == true)
        #expect(vehicle.system.driverAssist == "TeslaAP3")
        #expect(vehicle.system.tires.count == 4)
        #expect(vehicle.units.metricDistance == false)
        #expect(vehicle.units.fahrenheit == true)
    }

    /// Tesla reports doors and windows as open-angle codes, not booleans, and
    /// only the non-zero ones are actually ajar.
    @Test func onlyNonZeroDoorsAndWindowsCountAsOpen() {
        let vehicle = vehicle
        #expect(vehicle.security.openings == ["Passenger door"])
        #expect(vehicle.security.openWindows == ["Driver rear"])
    }

    /// Speed Limit Mode is the owner's governor. It is read, but it is never
    /// allowed to masquerade as the posted limit.
    @Test func speedLimitModeIsReadAsAGovernorNotAPostedLimit() {
        let vehicle = vehicle
        #expect(vehicle.drive.governorLimitMPH == 84)
        #expect(vehicle.drive.postedLimitMPH == nil)
    }

    @Test func ignoresAnInactiveSpeedLimitMode() throws {
        let json = try JSONValue.parse("""
        {"vehicle_state": {"speed_limit_mode": {"active": false, "current_limit_mph": 84}}}
        """)
        #expect(TessieSource.parse(state: json, fallbackVIN: "V").drive.governorLimitMPH == nil)
    }

    @Test func readsTheActiveRoute() throws {
        let route = try #require(vehicle.route)
        #expect(route.destination == "Empire State Building")
        #expect(route.trafficDelayMinutes == 12)
        #expect(route.energyAtArrival == 41)
    }

    /// Tesla leaves the whole `active_route_*` family populated with stale
    /// values after a route ends, so the destination name is what decides
    /// whether navigation is running at all.
    @Test func noDestinationNameMeansNoRoute() throws {
        let json = try JSONValue.parse("""
        {"drive_state": {"active_route_destination": "",
                         "active_route_minutes_to_arrival": 5.43}}
        """)
        #expect(TessieSource.parse(state: json, fallbackVIN: "V").route == nil)
    }

    /// Tesla stamps some timestamps in milliseconds and others in seconds.
    @Test func timestampsAreReadInEitherUnit() throws {
        let milliseconds = try #require(TessieSource.timestamp(.number(1_643_590_652_000)))
        let seconds = try #require(TessieSource.timestamp(.number(1_643_590_652)))
        #expect(milliseconds == seconds)
        // Sub-second precision survives the millisecond conversion.
        let fractional = try #require(TessieSource.timestamp(.number(1_643_590_652_755)))
        #expect(abs(fractional.timeIntervalSince(seconds) - 0.755) < 0.001)
        #expect(TessieSource.timestamp(.number(0)) == nil)
        #expect(TessieSource.timestamp(nil) == nil)
    }

    /// A sleeping car returns almost nothing. The panel must still get a
    /// vehicle back rather than a decode failure.
    @Test func aNearlyEmptyStateStillParses() throws {
        let json = try JSONValue.parse(#"{"state": "asleep"}"#)
        let vehicle = TessieSource.parse(state: json, fallbackVIN: "5YJ")
        #expect(vehicle.vin == "5YJ")
        #expect(vehicle.name == "Tesla")
        #expect(vehicle.isAsleep)
        #expect(!vehicle.isDriving)
        #expect(vehicle.drive.gear == .unknown)
    }

    /// Firmware adds shift states and charging states over time; one new
    /// string must not cost the panel its whole snapshot.
    @Test func unknownEnumeratedValuesDecodeRatherThanThrow() throws {
        let json = try JSONValue.parse("""
        {"state": "something_new", "drive_state": {"shift_state": "X"},
         "charge_state": {"charging_state": "Wireless"}}
        """)
        let vehicle = TessieSource.parse(state: json, fallbackVIN: "V")
        #expect(vehicle.connection == .unknown)
        #expect(vehicle.drive.gear == .unknown)
        #expect(vehicle.battery.state == .unknown)
    }

    /// `/state` carries coordinates but no street address; that lives only
    /// behind `/location`, and the two have to be folded together.
    @Test func theLocationResponseFillsInTheAddress() throws {
        var vehicle = vehicle
        #expect(vehicle.place.address == nil)
        let location = try JSONValue.parse("""
        {"latitude": 1, "longitude": 2,
         "address": "45500 Fremont Blvd, Fremont, California 94538, United States",
         "saved_location": "Work"}
        """)
        TessieSource.merge(location: location, into: &vehicle)
        #expect(vehicle.place.savedLocation == "Work")
        // The fresher coordinates from /state must win.
        #expect(vehicle.place.latitude == 37.4929681)
        // A saved name beats the postal address on a panel this size.
        #expect(vehicle.place.shortDescription == "Work")
    }

    @Test func aPostalAddressIsTrimmedToStreetAndTown() throws {
        var vehicle = TessieVehicle(vin: "V", name: "Car")
        TessieSource.merge(
            location: try JSONValue.parse("""
            {"address": "45500 Fremont Blvd, Fremont, California 94538, United States"}
            """),
            into: &vehicle)
        #expect(vehicle.place.shortDescription == "45500 Fremont Blvd, Fremont")
    }

    /// The second request is only worth making when a panel shows a place.
    @Test func theAddressIsOnlyFetchedWhenAFieldNeedsIt() {
        var settings = PanelSettings()
        settings.tessieParkedFields = [.battery, .lock]
        settings.tessieDrivingFields = [.speed]
        #expect(!TessieSource.needsAddress(settings))

        settings.tessieDrivingFields = [.speed, .map]
        #expect(TessieSource.needsAddress(settings))
    }

    /// Overpass is a volunteer-run service; a panel that never shows speed
    /// must never ask it anything.
    @Test func theSpeedLimitIsOnlyLookedUpWhileDrivingAndOnlyIfShown() {
        var settings = PanelSettings()
        settings.tessieDrivingFields = [.battery]
        #expect(!TessieSource.settingsShowSpeed(settings, isDriving: true))

        settings.tessieDrivingFields = [.speed]
        #expect(TessieSource.settingsShowSpeed(settings, isDriving: true))
        #expect(!TessieSource.settingsShowSpeed(settings, isDriving: false))
    }

    @Test func aRollingCarWithNoGearStillCountsAsDriving() {
        var vehicle = TessieVehicle(vin: "V", name: "Car")
        #expect(!vehicle.isDriving)
        vehicle.drive.speedMPH = 31
        #expect(vehicle.isDriving)
        vehicle.drive.gear = .park
        #expect(!vehicle.isDriving)
    }
}

@Suite struct TessieReadoutTests {
    var driving: TessieVehicle {
        TessieSource.parse(state: TessieParsingTests.drivingState, fallbackVIN: "V")
    }

    /// The whole point of the two field lists: the board rearranges itself
    /// when the car pulls away.
    @Test func contextFollowsTheCarUnlessItIsPinned() {
        var settings = PanelSettings()
        var parked = driving
        parked.drive.gear = .park
        parked.drive.speedMPH = 0

        #expect(TessieReadout.context(for: driving, settings: settings) == .driving)
        #expect(TessieReadout.context(for: parked, settings: settings) == .parked)

        settings.tessieAutoContext = false
        settings.tessieContext = .driving
        #expect(TessieReadout.context(for: parked, settings: settings) == .driving)

        // Before any data arrives there is no gear to follow.
        settings.tessieAutoContext = true
        #expect(TessieReadout.context(for: nil, settings: settings) == .driving)
    }

    @Test func eachContextDrawsItsOwnFieldList() {
        var settings = PanelSettings()
        settings.tessieParkedFields = [.battery, .lock]
        settings.tessieDrivingFields = [.speed]
        #expect(TessieReadout.fields(for: .parked, settings: settings) == [.battery, .lock])
        #expect(TessieReadout.fields(for: .driving, settings: settings) == [.speed])
    }

    /// A blank "Navigation —" tile is worse than no tile at all.
    @Test func fieldsWithNothingToSayAreDroppedNotBlank() {
        var vehicle = driving
        vehicle.route = nil
        let stats = TessieReadout.stats(for: vehicle, fields: [.navigation, .battery])
        #expect(stats.map(\.field) == [.battery])
    }

    @Test func speedIsColouredAgainstThePostedLimit() {
        var vehicle = driving
        vehicle.drive.speedMPH = 63
        vehicle.drive.postedLimitMPH = 65
        #expect(TessieReadout.stat(for: .speed, vehicle: vehicle)?.tone == .good)

        vehicle.drive.postedLimitMPH = 55
        #expect(TessieReadout.stat(for: .speed, vehicle: vehicle)?.tone == .warn)

        vehicle.drive.postedLimitMPH = 45
        let over = TessieReadout.stat(for: .speed, vehicle: vehicle)
        #expect(over?.tone == .bad)
        #expect(over?.detail?.contains("+18") == true)
    }

    /// With no posted limit the governor is shown, clearly labelled as a cap
    /// rather than a limit — it is not the same claim.
    @Test func theGovernorIsLabelledAsACapNotALimit() {
        var vehicle = driving
        vehicle.drive.postedLimitMPH = nil
        let stat = TessieReadout.stat(for: .speed, vehicle: vehicle)
        #expect(stat?.detail == "capped at 84 mph")
        #expect(stat?.tone == .accent)
    }

    /// Tessie publishes no live Autopilot engagement, so the field reports the
    /// hardware and never implies the car is steering itself.
    @Test func driverAssistReportsCapabilityOnly() {
        let stat = TessieReadout.stat(for: .driverAssist, vehicle: driving)
        #expect(stat?.value == "Full Self-Driving computer")
        #expect(stat?.detail?.contains("hardware") == true)
    }

    @Test func unitsFollowTheCarsOwnScreen() {
        var vehicle = driving
        #expect(TessieReadout.speed(63, units: vehicle.units) == "63 mph")
        #expect(TessieReadout.temperature(24.3, units: vehicle.units) == "76°F")

        vehicle.units = TessieVehicle.Units(metricDistance: true, fahrenheit: false)
        #expect(TessieReadout.speed(63, units: vehicle.units) == "101 km/h")
        #expect(TessieReadout.temperature(24.3, units: vehicle.units) == "24°C")
    }

    /// The arrival clock is anchored to the car's own timestamp; anchoring it
    /// to "now" would slide the ETA forward on every redraw.
    @Test func arrivalIsMeasuredFromWhenTheCarReported() throws {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        var route = TessieVehicle.Route()
        route.minutesToArrival = 30
        let arrival = try #require(route.arrival(from: captured))
        #expect(arrival.timeIntervalSince(captured) == 1800)
    }

    @Test func batteryToneWarnsBeforeItIsTooLate() {
        #expect(TessieReadout.batteryTone(80) == .good)
        #expect(TessieReadout.batteryTone(25) == .warn)
        #expect(TessieReadout.batteryTone(9) == .bad)
    }
}

@Suite struct RoadSpeedLimitTests {
    /// OpenStreetMap's `maxspeed` is km/h unless a unit is spelled out.
    @Test func parsesMaxSpeedTags() {
        #expect(RoadSpeedLimit.parseMaxSpeed("55 mph") == 55)
        #expect(RoadSpeedLimit.parseMaxSpeed("30mph") == 30)
        let fifty = try! #require(RoadSpeedLimit.parseMaxSpeed("50"))
        #expect(abs(fifty - 31.07) < 0.01)
        #expect(RoadSpeedLimit.parseMaxSpeed("none") == nil)
        #expect(RoadSpeedLimit.parseMaxSpeed("walk") == nil)
        #expect(RoadSpeedLimit.parseMaxSpeed("RU:urban") == nil)
        #expect(RoadSpeedLimit.parseMaxSpeed("0") == nil)
    }

    @Test func measuresDistanceToAPolylineNotJustItsVertices() {
        // A segment running due east, 0.001° north of the point. The nearest
        // vertex is far away along the segment; the segment itself is ~111 m.
        let distance = RoadSpeedLimit.distanceMeters(
            fromLatitude: 37.0, longitude: -122.0,
            toPolyline: [(37.001, -122.01), (37.001, -121.99)])
        #expect(abs(distance - 111.32) < 1)
    }

    /// A freeway usually runs alongside a frontage road with a very different
    /// limit, so "some road nearby" is not good enough — the nearest one wins.
    @Test func picksTheNearestWayNotTheFirstOne() throws {
        let json = try JSONValue.parse("""
        {"elements": [
          {"type": "way", "tags": {"highway": "motorway", "maxspeed": "65 mph"},
           "geometry": [{"lat": 37.00030, "lon": -122.001}, {"lat": 37.00030, "lon": -121.999}]},
          {"type": "way", "tags": {"highway": "service", "maxspeed": "25 mph"},
           "geometry": [{"lat": 37.00005, "lon": -122.001}, {"lat": 37.00005, "lon": -121.999}]}
        ]}
        """)
        #expect(RoadSpeedLimit.nearestLimit(in: json, latitude: 37.0, longitude: -122.0) == 25)
    }

    @Test func ignoresWaysBeyondTheSearchRadius() throws {
        let json = try JSONValue.parse("""
        {"elements": [
          {"type": "way", "tags": {"maxspeed": "65 mph"},
           "geometry": [{"lat": 37.002, "lon": -122.001}, {"lat": 37.002, "lon": -121.999}]}
        ]}
        """)
        #expect(RoadSpeedLimit.nearestLimit(in: json, latitude: 37.0, longitude: -122.0) == nil)
    }

    @Test func ignoresWaysWithNoUsableLimit() throws {
        let json = try JSONValue.parse("""
        {"elements": [
          {"type": "way", "tags": {"maxspeed": "none"},
           "geometry": [{"lat": 37.00005, "lon": -122.0}]}
        ]}
        """)
        #expect(RoadSpeedLimit.nearestLimit(in: json, latitude: 37.0, longitude: -122.0) == nil)
    }
}

@MainActor
@Suite struct TessieSettingsTests {
    /// A board edited on a newer build may carry a field this one has never
    /// heard of. Dropping just that field keeps the rest of the user's layout.
    @Test func anUnknownFieldIsDroppedWithoutResettingTheList() throws {
        let json = """
        {"tessieParkedFields": ["battery", "warpDrive", "lock"],
         "tessieDrivingFields": ["speed"],
         "tessieAutoContext": false, "tessieContext": "driving"}
        """
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data(json.utf8))
        #expect(settings.tessieParkedFields == [.battery, .lock])
        #expect(settings.tessieDrivingFields == [.speed])
        #expect(settings.tessieAutoContext == false)
        #expect(settings.tessieContext == .driving)
    }

    /// Panels saved before this feature existed must still open, on the
    /// sensible defaults.
    @Test func settingsFromBeforeTheTeslaPanelStillLoad() throws {
        let settings = try JSONDecoder().decode(PanelSettings.self,
                                                from: Data(#"{"refreshSeconds": 60}"#.utf8))
        #expect(settings.tessieParkedFields == TessieField.defaultParked)
        #expect(settings.tessieDrivingFields == TessieField.defaultDriving)
        #expect(settings.tessieAutoContext)
    }

    @Test func aRoundTripKeepsEveryField() throws {
        var settings = PanelSettings()
        settings.tessieParkedFields = [.map, .sentry]
        settings.tessieDrivingFields = [.speed, .arrival]
        settings.tessieAutoContext = false
        settings.tessieContext = .driving
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(PanelSettings.self, from: data) == settings)
    }

    /// A car's state changes by the minute; five is far too coarse.
    @Test func teslaPanelsRefreshFasterThanTheDefault() {
        #expect(PanelKind.tessie.defaultRefreshSeconds == 60)
        #expect(PanelKind.clock.defaultRefreshSeconds == 300)
    }

    /// One Tessie key covers a whole account, so rotating it must not leave
    /// half the board signed out — but the VIN is per-panel and stays put.
    @Test func sharingTheKeyLeavesEachPanelsVinAlone() throws {
        func teslaPanel(vin: String, key: String) -> Panel {
            var panel = Panel(kind: .tessie, title: "Car", frame: GridRect(x: 0, y: 0, width: 2, height: 1))
            var connector = ConnectorConfig()
            connector.token = key
            connector.query = vin
            panel.settings.connector = connector
            return panel
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-tessie-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("dashboards.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let store = DashboardStore(fileURL: url, authorsBoards: true)
        // Drop the starter board, so the board under test is dashboards[0].
        for existing in store.dashboards { store.delete(id: existing.id) }

        let edited = teslaPanel(vin: "VIN-A", key: "new-key")
        var board = Dashboard(name: "Cars")
        board.panels = [edited, teslaPanel(vin: "VIN-B", key: "old-key")]
        store.add(board)

        #expect(store.applyTessieCredentials(apiKey: "new-key", excluding: edited.id) == 1)
        #expect(store.dashboards[0].panels[1].settings.connector?.token == "new-key")
        #expect(store.dashboards[0].panels[1].settings.connector?.query == "VIN-B")
    }

    @Test func sharedDefaultsFillOnlyWhatAPanelIsMissing() {
        let shared = TessieCredentials.Snapshot(apiKey: "key-1", defaultVIN: "VIN-A")

        var empty = ConnectorConfig()
        TessieCredentials.fill(&empty, from: shared)
        #expect(empty.token == "key-1")
        #expect(empty.query == "VIN-A")

        // A panel deliberately pointed at the other car keeps its own VIN.
        var other = ConnectorConfig()
        other.query = "VIN-B"
        TessieCredentials.fill(&other, from: shared)
        #expect(other.token == "key-1")
        #expect(other.query == "VIN-B")
    }
}

// MARK: - Appearance

@Suite struct PanelAppearanceTests {
    /// The whole point of the hand-written decoding: a board written before
    /// appearances existed must still load, with everything at its default.
    @Test func settingsWithoutAnAppearanceStillDecode() throws {
        let legacy = """
        {"refreshSeconds": 60, "locationName": "Cupertino", "latitude": 37.3, "longitude": -122.0}
        """
        let settings = try JSONDecoder().decode(PanelSettings.self, from: Data(legacy.utf8))
        #expect(settings.appearance.isDefault)
        #expect(settings.appearance.theme == .board)
        #expect(settings.appearance.dynamic == .automatic)
        #expect(settings.weatherLocationMode == .coordinates)
        #expect(settings.weatherUnits == .automatic)
        #expect(settings.locationName == "Cupertino")
    }

    @Test func boardWithoutAnAppearanceStillDecodes() throws {
        let board = Dashboard(name: "Legacy")
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(board)) as! [String: Any]
        json.removeValue(forKey: "appearance")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Dashboard.self, from: stripped)
        #expect(decoded.appearance.isDefault)
        #expect(decoded.name == "Legacy")
    }

    @Test func appearanceSurvivesARoundTrip() throws {
        var appearance = PanelAppearance()
        appearance.theme = .glass
        appearance.backgroundStyle = .boardBackdrop
        appearance.material = .thin
        appearance.backgroundOpacity = 0.25
        appearance.glowRadius = 8
        appearance.dynamic = .weather
        var settings = PanelSettings()
        settings.appearance = appearance

        let decoded = try JSONDecoder().decode(
            PanelSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appearance == appearance)
        #expect(!decoded.appearance.isDefault)
    }

    /// A panel left on the default theme follows the board; one that has
    /// chosen its own keeps it, and an explicit accent beats a dynamic tint.
    @Test func boardThemeReachesPanelsUnlessTheyOverrideIt() {
        var board = BoardAppearance()
        board.theme = .paper

        let plain = Panel(kind: .text, title: "A", frame: GridRect(x: 0, y: 0, width: 1, height: 1))
        #expect(SBPanelStyle.themeName(panel: plain, board: board) == .paper)
        #expect(SBPanelStyle.resolve(panel: plain, board: board).isLight)

        var opinionated = plain
        opinionated.settings.appearance.theme = .terminal
        #expect(SBPanelStyle.themeName(panel: opinionated, board: board) == .terminal)

        board.appliesThemeToPanels = false
        #expect(SBPanelStyle.themeName(panel: plain, board: board) == .board)
    }

    @Test func lightThemesDarkenTheSemanticColors() {
        let dark = SBPanelStyle(palette: SBThemeName.board.palette)
        let light = SBPanelStyle(palette: SBThemeName.paper.palette)
        #expect(!dark.isLight)
        #expect(light.isLight)
        // The stock amber is unreadable on white, so a light theme must not
        // simply reuse it.
        #expect(light.warn != dark.warn)
    }

    /// Wallpapers and masked backdrops are drawn independently in every panel
    /// that shows them, so the noise they are built from has to be stable.
    @Test func backdropNoiseIsDeterministic() {
        #expect(sbNoise(7, 11) == sbNoise(7, 11))
        #expect(sbNoise(7, 11) != sbNoise(8, 11))
        for index in 0..<200 {
            let value = sbNoise(index, 3)
            #expect(value >= 0 && value < 1)
        }
    }

    @Test func gradientAnglesStayInsideTheUnitSquare() {
        for degrees in stride(from: 0.0, through: 360.0, by: 15) {
            let point = SBGradientFill.unitPoint(for: degrees)
            #expect(point.x >= 0 && point.x <= 1)
            #expect(point.y >= 0 && point.y <= 1)
        }
    }
}

@Suite struct DynamicAppearanceTests {
    private func panel(_ kind: PanelKind = .status,
                       configure: (inout PanelSettings) -> Void = { _ in }) -> Panel {
        var settings = PanelSettings()
        configure(&settings)
        return Panel(kind: kind, title: "T",
                     frame: GridRect(x: 0, y: 0, width: 1, height: 1), settings: settings)
    }

    @Test func weatherCodesMapToScenes() {
        #expect(WeatherScene.forCode(0) == .clear)
        #expect(WeatherScene.forCode(2) == .partlyCloudy)
        #expect(WeatherScene.forCode(3) == .overcast)
        #expect(WeatherScene.forCode(48) == .fog)
        #expect(WeatherScene.forCode(55) == .drizzle)
        #expect(WeatherScene.forCode(65) == .rain)
        #expect(WeatherScene.forCode(81) == .rain)
        #expect(WeatherScene.forCode(73) == .snow)
        #expect(WeatherScene.forCode(96) == .thunder)
    }

    @Test func automaticGivesAWeatherPanelASky() {
        let report = WeatherReport(locationName: "Home", temperatureC: 12,
                                   symbolName: "cloud.rain.fill",
                                   conditionDescription: "Rain", windKPH: 9, days: [],
                                   code: 63, isDaytime: false)
        let resolved = SBDynamicResolver.resolve(panel: panel(.weather),
                                                 snapshot: .weather(report),
                                                 style: .board)
        #expect(resolved.backdrop == .weather(report))
        #expect(resolved.tint == nil)
    }

    @Test func serviceStateColorsThePanel() {
        let style = SBPanelStyle.board
        func resolve(_ states: [ServiceStatus.State]) -> Color? {
            let statuses = states.enumerated().map {
                ServiceStatus(id: "\($0.offset)", name: "S", state: $0.element)
            }
            return SBDynamicResolver.resolve(panel: panel(), snapshot: .statuses(statuses),
                                             style: style).tint
        }
        #expect(resolve([.up, .up]) == style.good)
        #expect(resolve([.up, .degraded]) == style.warn)
        #expect(resolve([.degraded, .down]) == style.bad)
        // Nothing to say about an empty check, so nothing is drawn.
        #expect(resolve([]) == nil)
    }

    @Test func thresholdColoringFollowsTheAlertLimits() {
        let style = SBPanelStyle.board
        let hot = panel(.graph) { $0.alertAbove = 100; $0.appearance.dynamic = .threshold }
        func tint(_ value: Double) -> Color? {
            SBDynamicResolver.resolve(panel: hot, snapshot: .number(value, unit: nil),
                                      style: style).tint
        }
        #expect(tint(10) == style.good)
        // Within ten percent of the limit is the warning band.
        #expect(tint(95) == style.warn)
        #expect(tint(120) == style.bad)
    }

    @Test func offMeansOff() {
        let quiet = panel(.status) { $0.appearance.dynamic = .off }
        let statuses = [ServiceStatus(name: "S", state: .down)]
        let resolved = SBDynamicResolver.resolve(panel: quiet, snapshot: .statuses(statuses),
                                                 style: .board)
        #expect(resolved.backdrop == .none)
        #expect(resolved.tint == nil)
    }

    @Test func skyColorsChangeThroughTheDay() {
        let night = SBTimeOfDayBackdrop.colors(forHour: 2)
        let noon = SBTimeOfDayBackdrop.colors(forHour: 13)
        let dusk = SBTimeOfDayBackdrop.colors(forHour: 18)
        #expect(night != noon)
        #expect(noon != dusk)
        #expect(SBTimeOfDayBackdrop.colors(forHour: 23) == night)
    }
}

// MARK: - Weather sources

@Suite struct WeatherReportDecodingTests {
    /// Snapshots cached by an older build have no condition code and no
    /// daylight flag. Losing them would blank every weather panel until the
    /// next refresh, so they decode with sensible defaults instead.
    @Test func olderSnapshotsStillDecode() throws {
        let legacy = """
        {"locationName":"Ithaca","temperatureC":4.5,"symbolName":"cloud.fill",
         "conditionDescription":"Overcast","windKPH":11,"days":[]}
        """
        let report = try JSONDecoder().decode(WeatherReport.self, from: Data(legacy.utf8))
        #expect(report.code == -1)
        #expect(report.isDaytime)
        #expect(report.humidity == nil)
        #expect(report.locationName == "Ithaca")
    }

    @Test func nightSymbolsUseTheMoon() {
        #expect(WeatherSource.symbol(for: 0, isDaytime: true) == "sun.max.fill")
        #expect(WeatherSource.symbol(for: 0, isDaytime: false) == "moon.stars.fill")
        #expect(WeatherSource.symbol(for: 2, isDaytime: false) == "cloud.moon.fill")
        // Rain looks the same at midnight.
        #expect(WeatherSource.symbol(for: 63, isDaytime: false) == "cloud.rain.fill")
    }
}

@Suite struct StationWeatherTests {
    @Test func conditionTextMapsOntoWeatherCodes() {
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Thunderstorm")) == .thunder)
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Light Snow")) == .snow)
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Heavy Rain")) == .rain)
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Fog/Mist")) == .fog)
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Overcast")) == .overcast)
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Fair")) == .clear)
        #expect(WeatherScene.forCode(StationWeatherSource.code(forText: "Partly Cloudy")) == .partlyCloudy)
    }

    @Test func metarCloudLayersBecomeWords() {
        func layers(_ covers: [String]) -> [JSONValue] {
            covers.map { .object(["cover": .string($0)]) }
        }
        #expect(StationWeatherSource.cloudDescription(nil) == "Clear")
        #expect(StationWeatherSource.cloudDescription(layers(["FEW"])) == "Few Clouds")
        #expect(StationWeatherSource.cloudDescription(layers(["SCT", "BKN"])) == "Mostly Cloudy")
        #expect(StationWeatherSource.cloudDescription(layers(["OVC"])) == "Overcast")
    }

    @Test func humidityComesFromTheDewPoint() {
        // Dew point equal to the temperature is saturated air.
        #expect(abs(StationWeatherSource.relativeHumidity(temperature: 10, dewPoint: 10) - 100) < 0.01)
        let dry = StationWeatherSource.relativeHumidity(temperature: 30, dewPoint: 5)
        #expect(dry > 15 && dry < 30)
    }
}

@Suite struct PersonalWeatherStationTests {
    private func settings(_ format: PersonalWeatherFormat,
                          paths: [String: String] = [:]) -> PanelSettings {
        var settings = PanelSettings()
        settings.weatherPersonalURL = "http://192.168.1.50/data"
        settings.weatherPersonalFormat = format
        settings.weatherPersonalPaths = paths
        return settings
    }

    @Test func ecowittFahrenheitBecomesCelsius() throws {
        let json = try JSONValue.parse("""
        {"stationtype":"GW1100A","tempf":68.0,"humidity":55,"windspeedmph":10.0}
        """)
        let reading = try PersonalWeatherSource.reading(from: json, settings: settings(.automatic))
        #expect(abs(reading.temperatureC - 20) < 0.01)
        #expect(reading.humidity == 55)
        // 10 mph is a little over 16 km/h.
        #expect(abs((reading.windKPH ?? 0) - 16.09) < 0.05)
    }

    @Test func weewxCelsiusIsLeftAlone() throws {
        let json = try JSONValue.parse("""
        {"current":{"outTemp_C":18.4,"outHumidity":72,"windSpeed_kph":6.5}}
        """)
        let reading = try PersonalWeatherSource.reading(from: json, settings: settings(.weewx))
        #expect(abs(reading.temperatureC - 18.4) < 0.01)
        #expect(reading.humidity == 72)
    }

    @Test func homeAssistantEntityIsUnderstood() throws {
        let json = try JSONValue.parse("""
        {"entity_id":"weather.home","state":"rainy",
         "attributes":{"temperature":14.0,"humidity":88,"wind_speed":12.0,
                       "friendly_name":"Back Garden"}}
        """)
        let reading = try PersonalWeatherSource.reading(from: json,
                                                        settings: settings(.homeAssistant))
        #expect(abs(reading.temperatureC - 14) < 0.01)
        #expect(reading.conditionText == "rainy")
        #expect(reading.stationName == "Back Garden")
    }

    /// A station nobody has heard of: the reading is buried, but the key names
    /// are recognisable, so the parser digs it out rather than giving up.
    @Test func unknownShapesAreSearchedForRecognisableKeys() throws {
        let json = try JSONValue.parse("""
        {"sensors":{"outside":{"readings":{"outTemp_C":7.25,"humidity":91}}}}
        """)
        let reading = try PersonalWeatherSource.reading(from: json, settings: settings(.automatic))
        #expect(abs(reading.temperatureC - 7.25) < 0.01)
        #expect(reading.humidity == 91)
    }

    @Test func explicitPathsWinAndCustomNeverGuesses() throws {
        let json = try JSONValue.parse("""
        {"tempf":68.0,"mine":{"t":3.5}}
        """)
        let explicit = try PersonalWeatherSource.reading(
            from: json, settings: settings(.custom, paths: ["temperature": "mine.t"]))
        #expect(abs(explicit.temperatureC - 3.5) < 0.01)

        // Custom with no path set has nothing to fall back on, and says so
        // rather than silently reporting the wrong sensor.
        #expect(throws: PersonalWeatherSource.PWSError.self) {
            _ = try PersonalWeatherSource.reading(from: json, settings: settings(.custom))
        }
    }

    /// No outdoor station reads 60 °C, so a bare number that high is
    /// Fahrenheit whatever the key is called.
    @Test func impossibleCelsiusIsTreatedAsFahrenheit() {
        #expect(abs(PersonalWeatherSource.celsius(72, key: "temperature") - 22.22) < 0.01)
        #expect(abs(PersonalWeatherSource.celsius(22, key: "temperature") - 22) < 0.01)
        #expect(abs(PersonalWeatherSource.celsius(68, key: "tempf") - 20) < 0.01)
        #expect(abs(PersonalWeatherSource.celsius(20, key: "outTemp_C") - 20) < 0.01)
    }
}

@Suite struct WeatherLocationTests {
    @Test func summariesDescribeEachMode() {
        var settings = PanelSettings()
        settings.latitude = 42.44
        settings.longitude = -76.5
        #expect(settings.weatherLocationSummary.contains("42.44"))

        settings.weatherLocationMode = .place
        settings.locationName = "Ithaca"
        #expect(settings.weatherLocationSummary == "Ithaca")

        settings.weatherLocationMode = .station
        settings.weatherStationID = "KITH"
        #expect(settings.weatherLocationSummary.contains("KITH"))

        settings.weatherLocationMode = .current
        #expect(settings.weatherLocationSummary == "Ithaca")
    }

    @Test func geocodedPlacesReadBackWithTheirRegion() {
        let place = GeocodedPlace(name: "Springfield", detail: "Illinois, United States",
                                  latitude: 39.8, longitude: -89.65)
        #expect(place.displayName == "Springfield, Illinois, United States")
        let bare = GeocodedPlace(name: "Home", detail: "", latitude: 1, longitude: 2)
        #expect(bare.displayName == "Home")
        // Two geocoders finding the same town should not offer it twice.
        #expect(place.isRoughly(GeocodedPlace(name: "Springfield, IL", detail: "",
                                              latitude: 39.803, longitude: -89.652)))
        #expect(!place.isRoughly(bare))
    }

    @Test func openMeteoResultsParse() throws {
        let json = try JSONValue.parse("""
        {"results":[{"name":"Ithaca","latitude":42.44,"longitude":-76.5,
                     "admin1":"New York","country":"United States"}]}
        """)
        let entry = json["results"]!.arrayValue![0]
        let place = WeatherGeocoder.place(from: entry)
        #expect(place?.name == "Ithaca")
        #expect(place?.detail == "New York, United States")
        #expect(place?.latitude == 42.44)
    }
}

// MARK: - Home integrations

@Suite struct HVACAnalyzerTests {
    /// Builds a sample every `stepMinutes`, following a script of
    /// (status, minutes) segments, with a temperature that drifts the way the
    /// equipment would push it.
    func samples(from start: Date, stepMinutes: Double,
                 script: [(HVACStatus, Double)],
                 startTemperature: Double = 21,
                 driftPerMinute: Double = 0.02,
                 target: Double? = 21,
                 humidity: Double? = nil) -> [HVACSample] {
        var result: [HVACSample] = []
        var clock = start
        var temperature = startTemperature
        for (status, minutes) in script {
            var elapsed = 0.0
            while elapsed < minutes {
                result.append(HVACSample(date: clock, indoorC: temperature, targetC: target,
                                         humidity: humidity, status: status))
                let direction: Double = status == .heating ? 1 : (status == .cooling ? -1 : -0.2)
                temperature += direction * driftPerMinute * stepMinutes
                clock = clock.addingTimeInterval(stepMinutes * 60)
                elapsed += stepMinutes
            }
        }
        return result
    }

    let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    @Test func runsSplitOnStatusChangesAndIgnoreTheOpenEndedOnes() {
        let script: [(HVACStatus, Double)] = [(.off, 20), (.heating, 12), (.off, 20),
                                              (.heating, 12), (.off, 20)]
        let runs = HVACAnalyzer.runs(in: samples(from: epoch, stepMinutes: 1, script: script))
        #expect(runs.count == 5)
        // The first and last touch the edge of the window, so their lengths
        // are floors and they must not be counted as cycles.
        #expect(runs.first?.isComplete == false)
        #expect(runs.last?.isComplete == false)
        #expect(runs.filter { $0.status == .heating }.allSatisfy { $0.isComplete })
    }

    @Test func aFanRunningOnItsOwnIsNotACycle() {
        // A fan left on "circulate" would otherwise read as one huge run and
        // hide every real compressor cycle inside it.
        let script: [(HVACStatus, Double)] = [(.fan, 30), (.cooling, 15), (.fan, 30)]
        let runs = HVACAnalyzer.runs(in: samples(from: epoch, stepMinutes: 1, script: script))
        #expect(runs.filter { $0.status.isConditioning }.count == 1)
        #expect(runs.allSatisfy { $0.status != .fan })
    }

    @Test func healthyCyclingRaisesNothing() {
        // Twelve-minute runs, twice an hour: textbook.
        var script: [(HVACStatus, Double)] = []
        for _ in 0..<6 { script += [(.off, 18), (.heating, 12)] }
        let history = samples(from: epoch, stepMinutes: 1, script: script)
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 6,
                                          now: history.last!.date)
        #expect(result.hasEnoughHistory)
        #expect(result.cycles >= 4)
        #expect(!result.issues.contains { $0.id == "short-cycling" })
    }

    @Test func shortCyclingIsCaughtAndCarriesItsEvidence() {
        // Four-minute runs, eight times an hour.
        var script: [(HVACStatus, Double)] = []
        for _ in 0..<24 { script += [(.off, 4), (.cooling, 4)] }
        let history = samples(from: epoch, stepMinutes: 1, script: script)
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 6,
                                          now: history.last!.date)
        let issue = result.issues.first { $0.id == "short-cycling" }
        #expect(issue != nil)
        #expect(issue?.severity == .critical)
        // Every claim has to carry the numbers behind it.
        #expect(issue?.detail.contains("cycles") == true)
        #expect(result.cyclesPerHour > 5)
    }

    @Test func frequentButLongCyclesAreJustABusyDay() {
        // Six an hour, but running twelve minutes each — that is a hot day,
        // not a fault, and calling it one would teach people to ignore this.
        var script: [(HVACStatus, Double)] = []
        for _ in 0..<24 { script += [(.off, 3), (.cooling, 12)] }
        let history = samples(from: epoch, stepMinutes: 1, script: script)
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 6,
                                          now: history.last!.date)
        #expect(result.cyclesPerHour >= 3)
        #expect(!result.issues.contains { $0.id == "short-cycling" })
    }

    @Test func coolingWhileTheRoomWarmsIsCritical() {
        let history = samples(from: epoch, stepMinutes: 2,
                              script: [(.off, 30), (.cooling, 90), (.off, 30)],
                              startTemperature: 24,
                              // Positive drift while cooling: the wrong way.
                              driftPerMinute: -0.02, target: 21)
            .map { sample -> HVACSample in
                var copy = sample
                if sample.status == .cooling, let indoor = sample.indoorC {
                    copy.indoorC = indoor + 2 * sample.date.timeIntervalSince(epoch) / 3600
                }
                return copy
            }
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 6,
                                          now: history.last!.date)
        let issue = result.issues.first { $0.id == "wrong-direction" }
        #expect(issue?.severity == .critical)
        // The worst issue leads, so the panel's one line is the urgent one.
        #expect(result.issues.first?.id == "wrong-direction")
    }

    @Test func runningWithoutGainingGroundIsFlagged() {
        // Ninety minutes of heat, and the room never closes the gap.
        var history: [HVACSample] = []
        var clock = epoch
        for _ in 0..<60 {
            history.append(HVACSample(date: clock, indoorC: 18.0, targetC: 21, status: .heating))
            clock = clock.addingTimeInterval(120)
        }
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 6,
                                          now: history.last!.date)
        #expect(result.issues.contains { $0.id == "no-progress" })
    }

    @Test func aStaleThermostatSaysSoAndNothingElse() {
        var script: [(HVACStatus, Double)] = []
        for _ in 0..<24 { script += [(.off, 4), (.cooling, 4)] }
        let history = samples(from: epoch, stepMinutes: 1, script: script)
        // An hour after the last reading: everything below it is unknowable.
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 12,
                                          now: history.last!.date.addingTimeInterval(3600))
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.id == "stale")
    }

    @Test func tooLittleHistorySaysSoRatherThanAllClear() {
        let history = samples(from: epoch, stepMinutes: 5, script: [(.off, 20)])
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 12,
                                          now: history.last!.date)
        #expect(!result.hasEnoughHistory)
        #expect(result.issues.first?.id == "warming-up")
    }

    @Test func resolutionIsReportedFromTheMedianGap() {
        // One long gap (the app was asleep) must not make the whole history
        // look coarse.
        var history = samples(from: epoch, stepMinutes: 1, script: [(.off, 60)])
        let resumed = samples(from: history.last!.date.addingTimeInterval(7200),
                              stepMinutes: 1, script: [(.off, 60)])
        history += resumed
        #expect(abs(HVACAnalyzer.medianGapMinutes(history) - 1) < 0.001)
    }

    @Test func aMovingSetpointExplainsItsOwnSwing() {
        // Turning the heat up 3° is not a wide-swing fault.
        var history: [HVACSample] = []
        var clock = epoch
        for step in 0..<120 {
            let target = step < 60 ? 18.0 : 21.0
            history.append(HVACSample(date: clock, indoorC: target - 0.2,
                                      targetC: target, status: .heating))
            clock = clock.addingTimeInterval(180)
        }
        let result = HVACAnalyzer.analyze(samples: history, windowHours: 6,
                                          now: history.last!.date)
        #expect(!result.issues.contains { $0.id == "wide-swing" })
    }
}

@Suite struct HomeModelTests {
    @Test func contactAndLockSensorsAreNotInvertedByAccident() {
        // HomeKit reports 0 for "contact detected", which means *shut*, and
        // 1 for detected motion, which means moving. Getting this backwards
        // reports every closed door as open.
        #expect(!HomeKitMapping.isActive(kind: .contact, raw: 0))
        #expect(HomeKitMapping.isActive(kind: .contact, raw: 1))
        #expect(HomeKitMapping.isActive(kind: .motion, raw: 1))
        #expect(!HomeKitMapping.isActive(kind: .motion, raw: 0))
        // Lock: 1 is secured; jammed (2) and unknown (3) are not "locked".
        #expect(!HomeKitMapping.isActive(kind: .lock, raw: 1))
        #expect(HomeKitMapping.isActive(kind: .lock, raw: 2))
    }

    @Test func readingsReadBackInTheViewersOwnUnits() {
        let reading = HomeReading(id: "a", name: "Study", kind: .temperature, value: 20)
        #expect(reading.displayValue(units: .celsius) == "20°")
        #expect(reading.displayValue(units: .fahrenheit) == "68°")
        // A difference scales but does not offset — the mistake that turns a
        // 1 °C swing into a 34 °F one.
        #expect(SBTemperature.delta(1, units: .fahrenheit) == "1.8°")
        #expect(SBTemperature.full(20, units: .fahrenheit) == "68°F")
    }

    @Test func binaryReadingsSpeakTheirOwnLanguage() {
        var door = HomeReading(id: "d", name: "Back Door", kind: .contact)
        door.isActive = true
        #expect(door.displayValue(units: .celsius) == "Open")
        #expect(door.tone == .warn)
        var smoke = HomeReading(id: "s", name: "Hall", kind: .smoke)
        smoke.isActive = false
        #expect(smoke.tone == .good)
        smoke.isActive = true
        #expect(smoke.tone == .bad)
    }

    @Test func roomsSortAlphabeticallyWithTheUnassignedLast() {
        let report = HomeSensorReport(readings: [
            HomeReading(id: "1", name: "A", room: "Study", kind: .temperature, value: 20),
            HomeReading(id: "2", name: "B", kind: .temperature, value: 19),
            HomeReading(id: "3", name: "C", room: "Attic", kind: .humidity, value: 40),
            HomeReading(id: "4", name: "D", room: "Attic", kind: .temperature, value: 24),
        ])
        let rooms = report.byRoom.map(\.room)
        #expect(rooms == ["Attic", "Study", "Elsewhere"])
        // Within a room, temperature reads first.
        #expect(report.byRoom.first?.readings.first?.kind == .temperature)
        #expect(report.averageTemperatureC == 21)
    }

    @Test func theActiveSetpointIsWhicheverEndTheEquipmentIsChasing() {
        var readout = ThermostatReadout(id: "t", name: "Hall", currentC: 20,
                                        heatSetpointC: 19, coolSetpointC: 25,
                                        mode: .auto, status: .heating)
        #expect(readout.activeSetpointC == 19)
        readout.status = .cooling
        #expect(readout.activeSetpointC == 25)
        // Idle in a range: whichever end the room is nearer, so the trend
        // chart draws one line that means something.
        readout.status = .off
        #expect(readout.activeSetpointC == 19)
        readout.currentC = 24
        #expect(readout.activeSetpointC == 25)
        #expect(readout.setpointText(units: .celsius) == "19° – 25°")
    }

    @Test func downsamplingKeepsShortRunsVisible() {
        // A two-sample cooling blip inside a long idle stretch must survive
        // thinning, or the chart erases exactly what it exists to show.
        var history: [HVACSample] = []
        var clock = Date(timeIntervalSince1970: 1_770_000_000)
        for step in 0..<600 {
            let status: HVACStatus = (step == 300 || step == 301) ? .cooling : .off
            history.append(HVACSample(date: clock, indoorC: 21, targetC: 21, status: status))
            clock = clock.addingTimeInterval(60)
        }
        let thinned = HomeReadout.downsample(history, to: 60)
        #expect(thinned.count <= 61)
        #expect(thinned.contains { $0.status == .cooling })
    }

    @Test func homeSettingsSurviveARoundTripAndAnUnknownKind() {
        var settings = PanelSettings()
        settings.homeMode = .diagnostics
        settings.homeTarget = "climate.hallway"
        settings.homeRooms = ["Study", "Attic"]
        settings.homeSensorKinds = [.temperature, .motion]
        settings.hvacTrendHours = 24
        settings.showsHVACDiagnostics = false

        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(PanelSettings.self, from: data)
        #expect(decoded.homeMode == .diagnostics)
        #expect(decoded.homeTarget == "climate.hallway")
        #expect(decoded.homeRooms == ["Study", "Attic"])
        #expect(decoded.homeSensorKinds == [.temperature, .motion])
        #expect(decoded.hvacTrendHours == 24)
        #expect(!decoded.showsHVACDiagnostics)
    }

    @Test func oneUnknownSensorKindDoesNotResetTheWholeList() {
        // Same rule as the Tessie field lists: a kind this build doesn't know
        // drops out on its own rather than discarding every other choice.
        let json = Data("""
        {"homeSensorKinds": ["temperature", "neutrinoFlux", "motion"], "homeMode": "activity"}
        """.utf8)
        let settings = try! JSONDecoder().decode(PanelSettings.self, from: json)
        #expect(settings.homeSensorKinds == [.temperature, .motion])
        #expect(settings.homeMode == .activity)
    }

    @Test func aBoardSavedBeforeHomePanelsStillLoads() {
        let settings = try! JSONDecoder().decode(PanelSettings.self,
                                                 from: Data(#"{"refreshSeconds": 300}"#.utf8))
        #expect(settings.homeMode == .rooms)
        #expect(settings.homeSensorKinds.isEmpty)
        // Nothing chosen falls back to what the mode implies, not to a fixed
        // list — a rooms panel showing door sensors would not be a rooms panel.
        #expect(settings.resolvedSensorKinds == [.temperature, .humidity])
        var activity = settings
        activity.homeMode = .activity
        #expect(activity.resolvedSensorKinds == HomeSensorKind.activitySelection)
        var sensors = settings
        sensors.homeMode = .sensors
        #expect(sensors.resolvedSensorKinds == HomeSensorKind.defaultSelection)
        #expect(settings.hvacTrendHours == 12)
    }

    @Test func trendHoursAreClampedToSomethingChartable() {
        var settings = PanelSettings()
        settings.hvacTrendHours = 0
        #expect(settings.resolvedTrendHours == 1)
        settings.hvacTrendHours = 100_000
        #expect(settings.resolvedTrendHours == 168)
    }

    @Test func nestOffersOnlyWhatItsAPIActuallyHas() {
        // Cameras and free-standing sensors are not in the SDM API, so the
        // editor must not offer modes that would always fail.
        #expect(!HomeProvider.nest.supports(.camera))
        #expect(!HomeProvider.nest.supports(.sensors))
        #expect(HomeProvider.nest.supports(.thermostat))
        #expect(HomeProvider.homeKit.supports(.camera))
        #expect(HomeProvider.homeAssistant.supports(.camera))
    }
}

@Suite struct HomeAssistantParsingTests {
    let states = try! JSONValue.parse("""
    [
      {"entity_id":"sensor.study_temp","state":"68.4",
       "attributes":{"friendly_name":"Study Temperature","device_class":"temperature",
                     "unit_of_measurement":"°F"},
       "last_updated":"2026-08-07T12:00:00.123456+00:00"},
      {"entity_id":"sensor.attic_temp","state":"19.5",
       "attributes":{"friendly_name":"Attic","device_class":"temperature",
                     "unit_of_measurement":"°C"},
       "last_updated":"2026-08-07T12:00:00+00:00"},
      {"entity_id":"binary_sensor.back_door","state":"on",
       "attributes":{"friendly_name":"Back Door","device_class":"door"}},
      {"entity_id":"binary_sensor.hall_motion","state":"off",
       "attributes":{"friendly_name":"Hall","device_class":"motion"}},
      {"entity_id":"lock.front","state":"unlocked","attributes":{"friendly_name":"Front"}},
      {"entity_id":"sensor.random","state":"7","attributes":{"friendly_name":"Nothing"}},
      {"entity_id":"sensor.dead","state":"unavailable",
       "attributes":{"friendly_name":"Dead","device_class":"temperature"}},
      {"entity_id":"climate.hallway","state":"heat_cool",
       "attributes":{"friendly_name":"Hallway","current_temperature":68.0,
                     "target_temp_low":66.0,"target_temp_high":75.0,
                     "current_humidity":44,"hvac_action":"heating","fan_mode":"auto"}}
    ]
    """).arrayValue!

    @Test func sensorsAreClassifiedByDeviceClassNotByName() {
        let readings = HomeAssistantSource.readings(
            from: states, areas: ["sensor.study_temp": "Study"],
            kinds: Set(HomeSensorKind.allCases), rooms: [], fahrenheit: false)
        let ids = readings.map(\.id)
        #expect(ids.contains("sensor.study_temp"))
        #expect(ids.contains("binary_sensor.back_door"))
        #expect(ids.contains("lock.front"))
        // A sensor with no device class could be anything, so it is left out
        // rather than guessed at.
        #expect(!ids.contains("sensor.random"))
        #expect(readings.first { $0.id == "sensor.study_temp" }?.room == "Study")
    }

    @Test func eachSensorsOwnUnitWinsOverTheServerDefault() {
        let readings = HomeAssistantSource.readings(
            from: states, areas: [:], kinds: [.temperature], rooms: [], fahrenheit: false)
        let study = readings.first { $0.id == "sensor.study_temp" }
        let attic = readings.first { $0.id == "sensor.attic_temp" }
        // 68.4 °F is 20.2 °C — stored in Celsius whatever the sensor said.
        #expect(abs((study?.value ?? 0) - 20.22) < 0.05)
        #expect(attic?.value == 19.5)
    }

    @Test func unavailableEntitiesAreShownDimmedRatherThanDropped() {
        let readings = HomeAssistantSource.readings(
            from: states, areas: [:], kinds: [.temperature], rooms: [], fahrenheit: false)
        let dead = readings.first { $0.id == "sensor.dead" }
        #expect(dead != nil)
        #expect(dead?.isReachable == false)
        #expect(dead?.value == nil)
    }

    @Test func roomFilteringKeepsOnlyTheRoomsAsked() {
        let readings = HomeAssistantSource.readings(
            from: states, areas: ["sensor.study_temp": "Study", "sensor.attic_temp": "Attic"],
            kinds: [.temperature], rooms: ["Attic"], fahrenheit: false)
        #expect(readings.map(\.id) == ["sensor.attic_temp"])
    }

    @Test func climateEntitiesConvertFromTheServersUnit() {
        let readout = HomeAssistantSource.thermostat(from: states, areas: [:],
                                                     target: "climate.hallway",
                                                     fahrenheit: true)
        #expect(readout?.mode == .auto)
        #expect(readout?.status == .heating)
        #expect(abs((readout?.currentC ?? 0) - 20) < 0.05)
        #expect(abs((readout?.heatSetpointC ?? 0) - 18.89) < 0.05)
        #expect(readout?.humidity == 44)
        // In heat_cool the equipment chases the low end while heating.
        #expect(abs((readout?.activeSetpointC ?? 0) - 18.89) < 0.05)
    }

    @Test func aThermostatThatNeverReportsItsActionIsUnknownNotIdle() {
        // Counting silence as "off" would invent idle stretches and make the
        // cycling figures meaningless.
        #expect(HomeAssistantSource.status(from: nil, mode: "heat") == .unknown)
        #expect(HomeAssistantSource.status(from: nil, mode: "off") == .off)
        #expect(HomeAssistantSource.status(from: "idle", mode: "heat") == .off)
        #expect(HomeAssistantSource.status(from: "drying", mode: "cool") == .cooling)
    }

    @Test func fractionalTimestampsParse() {
        #expect(HomeAssistantSource.date(.string("2026-08-07T12:00:00.123456+00:00")) != nil)
        #expect(HomeAssistantSource.date(.string("2026-08-07T12:00:00+00:00")) != nil)
        #expect(HomeAssistantSource.date(.string("nonsense")) == nil)
    }

    @Test func addressesAreAcceptedTheWayPeopleTypeThem() {
        #expect(HomeAssistantCredentials.normalizedURL("homeassistant.local:8123")
                == "http://homeassistant.local:8123")
        #expect(HomeAssistantCredentials.normalizedURL("https://ha.example.com/lovelace/0")
                == "https://ha.example.com")
        #expect(HomeAssistantCredentials.normalizedURL("  ") == nil)
    }
}

@Suite struct NestParsingTests {
    let device = try! JSONValue.parse("""
    {
      "name":"enterprises/p1/devices/d1",
      "type":"sdm.devices.types.THERMOSTAT",
      "traits":{
        "sdm.devices.traits.Info":{"customName":""},
        "sdm.devices.traits.Connectivity":{"status":"ONLINE"},
        "sdm.devices.traits.Humidity":{"ambientHumidityPercent":35.0},
        "sdm.devices.traits.Temperature":{"ambientTemperatureCelsius":23.0},
        "sdm.devices.traits.ThermostatEco":{"availableModes":["MANUAL_ECO","OFF"],
                                            "mode":"OFF","heatCelsius":15.0,"coolCelsius":28.0},
        "sdm.devices.traits.ThermostatHvac":{"status":"COOLING"},
        "sdm.devices.traits.ThermostatMode":{"mode":"COOL"},
        "sdm.devices.traits.ThermostatTemperatureSetpoint":{"coolCelsius":22.0}
      },
      "parentRelations":[{"parent":"enterprises/p1/structures/s1/rooms/r1",
                          "displayName":"Hallway"}]
    }
    """)

    @Test func aThermostatReadsBackWithItsRoomAndSetpoint() {
        let readout = NestSource.readout(from: device)
        #expect(readout?.id == "enterprises/p1/devices/d1")
        // No custom name, so the room stands in — never the 40-character
        // resource path.
        #expect(readout?.name == "Hallway")
        #expect(readout?.room == "Hallway")
        #expect(readout?.currentC == 23)
        #expect(readout?.targetC == 22)
        #expect(readout?.mode == .cool)
        #expect(readout?.status == .cooling)
        #expect(readout?.humidity == 35)
        #expect(readout?.isOnline == true)
    }

    @Test func ecoHoldsItsOwnSetpointsNotTheScheduledOnes() {
        var json = device
        guard case .object(var root) = json, case .object(var traits) = root["traits"]! else {
            Issue.record("bad fixture"); return
        }
        traits["sdm.devices.traits.ThermostatEco"] = .object([
            "mode": .string("MANUAL_ECO"), "heatCelsius": .number(15), "coolCelsius": .number(28),
        ])
        traits["sdm.devices.traits.ThermostatMode"] = .object(["mode": .string("HEATCOOL")])
        root["traits"] = .object(traits)
        json = .object(root)

        let readout = NestSource.readout(from: json)
        #expect(readout?.mode == .eco)
        #expect(readout?.holdLabel == "Eco")
        // The Eco range, not the 22° schedule — otherwise the panel shows a
        // target the equipment is not chasing.
        #expect(readout?.heatSetpointC == 15)
        #expect(readout?.coolSetpointC == 28)
    }

    @Test func aThermostatDoublesAsItsRoomsTemperature() {
        let readings = NestSource.readings(fromDevice: device)
        #expect(readings.count == 2)
        #expect(readings.first?.kind == .temperature)
        #expect(readings.first?.room == "Hallway")
        // Two readings from one device must not collide on id.
        #expect(Set(readings.map(\.id)).count == 2)
    }

    @Test func theAuthorizationURLIsThePartnerConnectionOne() {
        // accounts.google.com would authenticate but return no devices — the
        // partner-connection endpoint is what links the Device Access project.
        let url = NestCredentials.authorizationURL(
            NestCredentials.Setup(projectID: "p1", clientID: "c1", clientSecret: "s"))
        let text = url?.absoluteString ?? ""
        #expect(text.hasPrefix("https://nestservices.google.com/partnerconnections/p1/auth"))
        #expect(text.contains("access_type=offline"))
        // Without prompt=consent Google reuses an earlier grant and returns
        // no refresh token, which fails an hour later.
        #expect(text.contains("prompt=consent"))
        #expect(NestCredentials.authorizationURL(NestCredentials.Setup()) == nil)
    }

    @Test func thePastedCodeIsTakenHoweverItArrives() {
        #expect(NestCredentials.authorizationCode(
            fromPasted: "https://www.google.com/?code=4/abc-DEF&scope=https://x") == "4/abc-DEF")
        #expect(NestCredentials.authorizationCode(fromPasted: "  4/abc-DEF ") == "4/abc-DEF")
        #expect(NestCredentials.authorizationCode(fromPasted: "") == nil)
    }
}
