import SwiftUI
import StatusBoardKit

@main
struct StatusBoardiOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    model.start()
                    // A status board should stay on like the original app did.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
        .commands { StatusBoardCommands(model: model) }
    }
}
