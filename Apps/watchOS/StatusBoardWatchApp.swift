import SwiftUI
import AppIntents
import StatusBoardKit

@main
struct StatusBoardWatchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { model.start() }
        }
    }
}

/// Surfaces the package's intents (Push Value, Get Value) to Shortcuts.
struct StatusBoardAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [StatusBoardKitIntents.self]
    }
}
