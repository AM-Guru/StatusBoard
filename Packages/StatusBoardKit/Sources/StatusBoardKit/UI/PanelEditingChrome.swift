import SwiftUI

/// How much bigger a board's editing controls have to be drawn to come out the
/// right size on screen.
///
/// The device simulator lays a board out at the target screen's real point size
/// and then scales the whole thing down to fit the window — a 1920-point TV
/// board in a 700-point pane is drawn at about a third size. Everything on it
/// shrinks with it, which is the point for panel text but ruinous for a resize
/// grip: at a third size a comfortable 44-point target is 15 points across and
/// nobody can hit it. The simulator publishes the inverse of its scale here and
/// the editing chrome multiplies by it, so grips and buttons stay the same size
/// under the pointer however far the board has been shrunk.
private struct SBEditorControlScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    public var sbEditorControlScale: CGFloat {
        get { self[SBEditorControlScaleKey.self] }
        set { self[SBEditorControlScaleKey.self] = newValue }
    }
}

#if !os(tvOS) && !os(watchOS)
/// Which corner of a panel a resize drag has hold of.
///
/// Pulling a top or leading corner moves the panel's origin as well as its
/// size. Without that a panel can only ever be grown down and to the right, so
/// making one taller upwards meant a resize followed by a move to put it back.
public enum SBResizeCorner: CaseIterable, Hashable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// True when dragging this corner moves the panel's left edge rather than
    /// its right one.
    var movesLeadingEdge: Bool { self == .topLeading || self == .bottomLeading }

    /// True when dragging this corner moves the panel's top edge rather than
    /// its bottom one.
    var movesTopEdge: Bool { self == .topLeading || self == .topTrailing }

    var displayName: String {
        switch self {
        case .topLeading: return "top left"
        case .topTrailing: return "top right"
        case .bottomLeading: return "bottom left"
        case .bottomTrailing: return "bottom right"
        }
    }

    #if os(macOS)
    /// The cursor shown over this grip. Mac-only: the resize cursors are an
    /// AppKit idea, and the pointer on iPadOS has no equivalent.
    var pointerPosition: FrameResizePosition {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
    #endif
}
#endif
