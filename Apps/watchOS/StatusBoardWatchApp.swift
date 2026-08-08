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

/// Gives Siri on Apple Watch the same concise phrases as iPhone and Mac.
struct StatusBoardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PushValueIntent(),
            phrases: ["Push a value to \(.applicationName)"],
            shortTitle: "Push Value",
            systemImageName: "arrow.up.circle")
        AppShortcut(
            intent: GetPanelValueIntent(),
            phrases: ["Get a value from \(.applicationName)"],
            shortTitle: "Get Value",
            systemImageName: "gauge")
    }
}
