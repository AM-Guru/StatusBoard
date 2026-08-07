import Foundation
import CoreGraphics

/// Reflows a board onto an Apple Watch.
///
/// A watch is far too narrow to honour the board's grid literally, so panels
/// keep their *reading order* and their relative emphasis instead of their
/// coordinates: a panel that occupies most of a board row still gets a row of
/// its own, and small panels pair up when the screen is wide enough to keep
/// them legible. Kept free of any platform guard so it can be unit tested.
public enum WatchLayout {

    /// How much horizontal room the watch gives us.
    public enum Width: Sendable, Equatable {
        /// 40/41/42 mm — one panel per row.
        case compact
        /// 44/45/46/49 mm — small panels can sit two abreast.
        case regular
    }

    /// 45 mm and larger report at least 184 pt of screen width; the 41 mm
    /// reports 176 pt. The boundary sits between them.
    public static func width(forScreenWidth width: CGFloat) -> Width {
        width >= 180 ? .regular : .compact
    }

    /// Panels whose content is a chart, a list or a table are unreadable at
    /// half width, so they always take the full row.
    public static func prefersFullWidth(_ kind: PanelKind) -> Bool {
        switch kind {
        case .graph, .table, .feed, .calendar, .logs, .webClip, .image,
             .grades, .schedule, .assignments, .canvas, .k12schedule,
             .github, .appStoreConnect, .supabase, .status, .tessie,
             .homeKit, .homeAssistant, .nest:
            return true
        case .clock, .weather, .progress, .text, .countdown, .mcp, .bridge, .health:
            return false
        }
    }

    /// True when the panel is wide enough on the board to deserve its own row.
    public static func isWide(_ panel: Panel, boardColumns: Int) -> Bool {
        if prefersFullWidth(panel.kind) { return true }
        guard boardColumns > 0 else { return false }
        return Double(panel.frame.width) / Double(boardColumns) > 0.5
    }

    /// Groups panels into rows of one or two, preserving order.
    public static func rows(for panels: [Panel],
                            boardColumns: Int,
                            width: Width) -> [[Panel]] {
        var rows: [[Panel]] = []
        var pending: Panel?

        func flush() {
            if let panel = pending { rows.append([panel]); pending = nil }
        }

        for panel in panels {
            if width == .compact || isWide(panel, boardColumns: boardColumns) {
                flush()
                rows.append([panel])
            } else if let partner = pending {
                rows.append([partner, panel])
                pending = nil
            } else {
                pending = panel
            }
        }
        flush()
        return rows
    }

    /// Height for a tile, scaled to the screen so the same board reads the
    /// same way on a 40 mm and a 49 mm watch.
    public static func tileHeight(forScreenWidth screenWidth: CGFloat,
                                  isFullWidth: Bool) -> CGFloat {
        let unit = max(screenWidth, 120) * (isFullWidth ? 0.46 : 0.60)
        return min(max(unit, 56), 132)
    }
}
