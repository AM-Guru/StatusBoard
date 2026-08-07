import SwiftUI
import StatusBoardKit

@main
struct StatusBoardMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 540)
                .task { model.start() }
        }
        // Arranging a 1920×1080 board wants room, and this window is now where
        // that happens rather than in a sheet.
        .defaultSize(width: 1400, height: 900)
        .commands { StatusBoardCommands(model: model) }

        // Appears in the Window menu; hosts the bridge server controls.
        Window("Bridge Console", id: "bridge-console") {
            BridgeConsoleView(server: model.bridgeServer)
        }
        .defaultSize(width: 520, height: 620)

        Settings {
            BridgeConsoleView(server: model.bridgeServer)
        }

        MenuBarExtra("Status Board", systemImage: "gauge.with.dots.needle.67percent") {
            MenuBarContent(model: model)
        }
    }
}

/// Quick bridge status and controls from the menu bar.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.bridgeServer.isRunning {
                Text("Bridge running · port \(String(model.bridgeServer.port)) · \(model.bridgeServer.subscriberCount) device(s)")
            } else {
                Text("Bridge stopped")
            }
            Button(model.bridgeServer.isRunning ? "Stop Bridge" : "Start Bridge") {
                model.bridgeServer.isRunning ? model.bridgeServer.stop() : model.bridgeServer.start()
            }
            Divider()
            Button("Bridge Console…") {
                openWindow(id: "bridge-console")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Open Status Board") {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
