import Foundation
import Testing
@testable import StatusBoardKit

/// The Smart Glasses screen. Status Board never runs on the glasses — SybilSight
/// draws its boards there — so what is tested here is the arrangement Status
/// Board is responsible for producing, and the link that decides whether the
/// screen is offered at all.
@Suite struct GlassesScreenTests {

    private func board() -> Dashboard {
        var board = Dashboard(name: "Ops", grid: BoardGrid(columns: 8, rows: 4))
        board.panels = [
            Panel(kind: .clock, title: "Clock", frame: GridRect(x: 0, y: 0, width: 2, height: 1)),
            Panel(kind: .progress, title: "CPU", frame: GridRect(x: 2, y: 0, width: 2, height: 1)),
            Panel(kind: .webClip, title: "Site", frame: GridRect(x: 4, y: 0, width: 4, height: 2)),
            Panel(kind: .text, title: "Note", frame: GridRect(x: 0, y: 1, width: 4, height: 1)),
        ]
        return board
    }

    // MARK: - The screen itself

    /// The raw value is the key SybilSight reads the arrangement out of. If it
    /// ever changes, every wearer's glasses layout silently stops being found.
    @Test func theStorageKeyIsTheOneSybilSightReads() {
        #expect(SBDeviceClass.glasses.rawValue == "glasses")
        #expect(SBDeviceClass(rawValue: "glasses") == .glasses)
    }

    @Test func theCanvasIsTheRealOne() {
        #expect(SBDeviceClass.glasses.nominalPointSize == CGSize(width: 576, height: 288))
        #expect(SBDeviceClass.glasses.isMonochrome)
        // Nothing to scroll with on a pair of lenses.
        #expect(SBDeviceClass.glasses.allowsScrolling == false)
        #expect(SBDeviceClass.glasses.usesAutomaticLayout)
        #expect(SBDeviceClass.glasses.supportsRotation == false)
    }

    @Test func theGlassesAreNeverThisDevice() {
        // No Status Board target runs on glasses, so `.current` must never
        // resolve to one — that would make an ordinary Mac window try to render
        // itself as a 576×288 strip.
        #expect(SBDeviceClass.current != .glasses)
    }

    /// The guide is the eyebox, not overscan, and it must say so — the copy is
    /// the only thing telling a wearer why the dashed line is there.
    @Test func theScreenGuideIsAboutTheEyeboxNotOverscan() throws {
        let guide = try #require(SBDeviceClass.glasses.screenGuide)
        #expect(guide.inset != .zero)
        #expect(guide.sectionTitle == "Eyebox")
        #expect(!guide.explanation.contains("television"))
        // The TV keeps its own wording.
        let tv = try #require(SBDeviceClass.tv.screenGuide)
        #expect(tv.sectionTitle == "Overscan")
        #expect(SBDeviceClass.mac.screenGuide == nil)
    }

    // MARK: - Arranging

    /// The panels a monochrome strip can't carry are hidden by the arrangement
    /// rather than left to draw grey mush across a quarter of the lenses.
    @Test func autoArrangingDropsThePanelsTheLensesCannotDraw() {
        let board = board()
        let layout = SBAutoLayout.layout(for: board, device: .glasses)
        let site = board.panels.first { $0.title == "Site" }!
        #expect(layout.hiddenPanelIDs.contains(site.id.uuidString))
        for panel in board.panels where panel.title != "Site" {
            #expect(!layout.hiddenPanelIDs.contains(panel.id.uuidString))
        }
    }

    @Test func autoArrangingKeepsEverythingInsideTheGrid() {
        let board = board()
        let layout = SBAutoLayout.layout(for: board, device: .glasses)
        let grid = layout.grid ?? SBDeviceClass.glasses.suggestedGrid
        #expect(grid.columns == 2)
        for panel in board.panels where !layout.hiddenPanelIDs.contains(panel.id.uuidString) {
            let frame = layout.frames[panel.id.uuidString]!
            #expect(frame.x >= 0)
            #expect(frame.x + frame.width <= grid.columns)
        }
    }

    /// Arranging the glasses must not touch any other screen. A wearer tuning
    /// their lenses should never find their Apple TV rearranged.
    @Test func arrangingTheGlassesLeavesOtherScreensAlone() {
        var board = board()
        board.deviceLayouts[SBDeviceClass.glasses.rawValue] =
            SBAutoLayout.layout(for: board, device: .glasses)
        #expect(board.hasCustomLayout(for: .glasses))
        for device in [SBDeviceClass.mac, .pad, .tv, .phone, .watch] {
            #expect(board.hasCustomLayout(for: device) == false)
        }
        #expect(board.panels(for: .mac).map(\.frame) == board.panels.map(\.frame))
    }

    @Test func panelSupportIsGlassesOnly() {
        #expect(SBDeviceClass.glasses.supports(.clock))
        #expect(SBDeviceClass.glasses.supports(.progress))
        #expect(SBDeviceClass.glasses.supports(.webClip) == false)
        #expect(SBDeviceClass.glasses.supports(.image) == false)
        // Every other screen draws everything.
        for device in SBDeviceClass.allCases where device != .glasses {
            #expect(device.unsupportedPanelKinds.isEmpty)
        }
    }

    // MARK: - Wire

    /// The identity message has to survive a round trip, and an older client
    /// that sends nothing at all must still be able to subscribe.
    @Test func theIdentityMessageRoundTrips() throws {
        let identity = BridgeClientIdentity(
            id: "abc", name: "Kalani's iPhone", deviceClass: "glasses",
            app: "SybilSight", hardware: "Even Realities G2")
        let line = try #require(BridgeMessage.identity(identity).encodedLine())
        let decoded = try #require(BridgeMessage.decodeLine(line.dropLast()))
        guard case .identity(let round) = decoded else {
            Issue.record("expected an identity message")
            return
        }
        #expect(round == identity)
    }

    @Test func theSubscribeHandshakeIsUnchanged() {
        // Older iPhones, Apple TVs and Watches send exactly this and nothing
        // else. Changing it would strand every one of them.
        #expect(BridgeMessage.subscribeHandshake == "SB SUBSCRIBE 1")
    }

    /// Only a client that says it draws the glasses counts. An Apple TV
    /// subscribing for panel data must not put a Smart Glasses entry in the menu.
    @Test func anOrdinaryDisplaySubscriberIsNotAPairOfGlasses() {
        let identity = BridgeClientIdentity(
            id: "tv", name: "Living Room", deviceClass: SBDeviceClass.tv.rawValue,
            app: "Status Board")
        #expect(identity.device == .tv)
        let glasses = BridgeClientIdentity(
            id: "g", name: "Phone", deviceClass: "glasses", app: "SybilSight")
        #expect(glasses.device == .glasses)
        let unknown = BridgeClientIdentity(id: "x", name: "Thing", deviceClass: "toaster")
        #expect(unknown.device == nil)
    }
}

/// Whether the Smart Glasses screen is offered at all. Main-actor because the
/// link is observed from SwiftUI menus.
@MainActor
@Suite struct GlassesLinkTests {

    private func freshLink() -> GlassesLink {
        let defaults = UserDefaults(suiteName: "sb.glasses.tests.\(UUID().uuidString)")!
        return GlassesLink(defaults: defaults)
    }

    @Test func theScreenIsNotOfferedUntilSomethingIsLinked() {
        let link = freshLink()
        // On a Mac with nothing connected and SybilSight nowhere in sight.
        #expect(link.connected == nil)
        #expect(link.wasSeenRecently == false)
    }

    @Test func aSubscribedPairOffersTheScreenAndNamesItself() {
        let link = freshLink()
        link.report(connected: BridgeClientIdentity(
            id: "abc", name: "Kalani's iPhone",
            deviceClass: SBDeviceClass.glasses.rawValue,
            app: "SybilSight", hardware: "Even Realities G2"))
        #expect(link.isOffered)
        #expect(link.isLive)
        #expect(link.displayName == "Kalani's iPhone")
        #expect(link.statusDescription.contains("Even Realities G2"))
    }

    /// A phone going into a pocket must not retract a screen someone is in the
    /// middle of arranging.
    @Test func aDroppedLinkIsRememberedRatherThanForgotten() {
        let link = freshLink()
        link.report(connected: BridgeClientIdentity(
            id: "abc", name: "Kalani's iPhone",
            deviceClass: SBDeviceClass.glasses.rawValue))
        link.report(connected: nil)
        #expect(link.isLive == false)
        #expect(link.isOffered)                 // still offered
        #expect(link.displayName == "Kalani's iPhone")
        #expect(link.statusDescription.contains("last showed"))
    }

    @Test func theScreenCanBeForcedOnBeforeAnythingIsLinked() {
        let link = freshLink()
        #expect(link.isOffered == false || link.sybilSightIsInstalledHere)
        link.alwaysOffered = true
        #expect(link.isOffered)
    }

}
