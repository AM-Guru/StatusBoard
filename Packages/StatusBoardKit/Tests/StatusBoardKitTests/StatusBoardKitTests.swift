import Foundation
import CryptoKit
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
        #expect(TableContentView.statusColor(for: " Success ") == SBTheme.good)
        #expect(TableContentView.statusColor(for: "DEGRADED") == SBTheme.warn)
        #expect(TableContentView.statusColor(for: "failed") == SBTheme.bad)
        #expect(TableContentView.statusColor(for: "building") == SBTheme.secondaryAccent)
        #expect(TableContentView.statusColor(for: "hello") == nil)
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
