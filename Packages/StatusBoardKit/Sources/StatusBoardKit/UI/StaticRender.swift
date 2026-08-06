import SwiftUI

/// Set while a board is being rendered to an image rather than shown on screen.
///
/// Two things need to know: live views (web clips) substitute static content,
/// and scrolling containers unwrap themselves — `ImageRenderer` rasterises a
/// `ScrollView` as empty, so a panel that scrolls would vanish from the export.
///
/// Deliberately outside the poster's platform guard: the views that consult it
/// are shared with tvOS and watchOS, where it simply stays false.
private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var isStaticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}
