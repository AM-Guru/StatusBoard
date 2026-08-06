import AppIntents
import StatusBoardKit

/// Surfaces the package's intents (Push Value, Get Value) to Shortcuts.
struct StatusBoardAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [StatusBoardKitIntents.self]
    }
}

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
