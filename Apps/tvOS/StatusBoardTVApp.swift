import SwiftUI
import StatusBoardKit

@main
struct StatusBoardTVApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { model.start() }
        }
    }
}
