import Foundation
#if canImport(CoreSpotlight) && !os(tvOS)
import CoreSpotlight
#endif

/// Puts boards and panels in Spotlight, so searching "CPU" from the Home
/// Screen or ⌘-Space jumps straight to the board showing it. Panel entries
/// carry their latest value in the subtitle, which keeps search results
/// useful rather than merely navigational.
public enum SpotlightIndexer {
    /// Identifier prefix so we can delete only our own items.
    static let domain = "guru.am.statusboard.boards"

    /// Activity type used for both Spotlight taps and Handoff.
    public static let activityType = "guru.am.statusboard.viewBoard"
    public static let boardIDKey = "boardID"

    #if canImport(CoreSpotlight) && !os(tvOS)
    public static func index(dashboards: [Dashboard],
                             records: [String: SnapshotRecord]) {
        var items: [CSSearchableItem] = []

        for board in dashboards {
            let boardAttributes = CSSearchableItemAttributeSet(contentType: .content)
            boardAttributes.title = board.name
            boardAttributes.contentDescription =
                "Status Board dashboard · \(board.panels.count) panel\(board.panels.count == 1 ? "" : "s")"
            boardAttributes.keywords = ["dashboard", "status board"] + board.panels.map(\.title)
            items.append(CSSearchableItem(uniqueIdentifier: identifier(board: board.id),
                                          domainIdentifier: domain,
                                          attributeSet: boardAttributes))

            for panel in board.panels {
                let attributes = CSSearchableItemAttributeSet(contentType: .content)
                attributes.title = panel.title
                let value = AccessibilitySummary.value(for: records[panel.snapshotKey]?.snapshot,
                                                       settings: panel.settings)
                attributes.contentDescription = "\(board.name) · \(panel.kind.displayName)\n\(value)"
                attributes.keywords = [panel.kind.displayName, board.name]
                items.append(CSSearchableItem(
                    uniqueIdentifier: identifier(board: board.id, panel: panel.id),
                    domainIdentifier: domain,
                    attributeSet: attributes))
            }
        }

        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }
    #else
    public static func index(dashboards: [Dashboard], records: [String: SnapshotRecord]) {}
    #endif

    static func identifier(board: Dashboard.ID, panel: Panel.ID? = nil) -> String {
        guard let panel else { return "board/\(board.uuidString)" }
        return "board/\(board.uuidString)/panel/\(panel.uuidString)"
    }

    /// Extracts the board id from a Spotlight identifier or Handoff payload.
    public static func boardID(fromIdentifier identifier: String) -> Dashboard.ID? {
        let parts = identifier.split(separator: "/")
        guard parts.count >= 2, parts[0] == "board" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
}
