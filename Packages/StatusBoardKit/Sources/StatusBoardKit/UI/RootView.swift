import SwiftUI

/// Platform-adaptive app root. iOS/iPadOS/macOS get a sidebar of dashboards
/// with an editable detail board; tvOS gets a full-screen paged experience.
public struct RootView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            #if os(tvOS)
            TVRootView(model: model)
            #elseif os(watchOS)
            WatchRootView(model: model)
            #else
            SplitRootView(model: model)
            #endif
        }
        .preferredColorScheme(.dark)
        .tint(SBTheme.accent)
        #if !os(tvOS)
        // Spotlight results and Handoff both land here.
        .onContinueUserActivity(SpotlightIndexer.activityType) { activity in
            model.handleActivity(activity)
        }
        .onContinueUserActivity("com.apple.corespotlightitem") { activity in
            model.handleActivity(activity)
        }
        .userActivity(SpotlightIndexer.activityType) { activity in
            guard let board = model.store.selectedDashboard else { return }
            activity.title = board.name
            activity.userInfo = [SpotlightIndexer.boardIDKey: board.id.uuidString]
            activity.isEligibleForHandoff = true
        }
        #endif
    }
}

// MARK: - iOS / iPadOS / macOS

#if !os(tvOS) && !os(watchOS)
struct SplitRootView: View {
    @Bindable var model: AppModel
    @State private var renamingBoard: Dashboard?
    @State private var renameText = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: Binding(
            get: { model.inspectedPanelID != nil },
            set: { if !$0 { model.inspectedPanelID = nil } })) {
            if let inspected = model.inspectedPanel() {
                PanelInspectorView(model: model,
                                   panel: inspected.panel,
                                   dashboardID: inspected.dashboardID)
            }
        }
        .alert("Rename Dashboard", isPresented: Binding(
            get: { renamingBoard != nil },
            set: { if !$0 { renamingBoard = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if var board = renamingBoard {
                    board.name = renameText
                    model.store.update(board)
                }
                renamingBoard = nil
            }
            Button("Cancel", role: .cancel) { renamingBoard = nil }
        }
    }

    var sidebar: some View {
        @Bindable var store = model.store
        return List(selection: $store.selectedDashboardID) {
            ForEach(model.store.dashboards) { board in
                Label(board.name, systemImage: "rectangle.grid.2x2")
                    .tag(board.id)
                    .contextMenu {
                        Button("Rename") {
                            renameText = board.name
                            renamingBoard = board
                        }
                        Button("Delete", role: .destructive) {
                            model.store.delete(id: board.id)
                        }
                    }
            }
        }
        .navigationTitle("Status Board")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        model.store.add(Dashboard(name: "New Board"))
                    } label: {
                        Label("Empty Board", systemImage: "rectangle.dashed")
                    }
                    Section("Samples") {
                        Button {
                            model.store.add(.macVitals())
                        } label: {
                            Label("Mac Vitals", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        Button {
                            model.store.add(.worldClocks())
                        } label: {
                            Label("World Clocks", systemImage: "globe")
                        }
                    }
                } label: {
                    Label("New Dashboard", systemImage: "plus")
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        #endif
    }

    @ViewBuilder
    var detail: some View {
        if let board = model.store.selectedDashboard {
            BoardView(model: model, dashboardID: board.id)
                .navigationTitle(board.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(SBTheme.background, for: .navigationBar)
                #endif
                .toolbar { boardToolbar(board: board) }
        } else {
            ContentUnavailableView("No Dashboard",
                                   systemImage: "rectangle.grid.2x2",
                                   description: Text("Create a dashboard to get started."))
        }
    }

    @ToolbarContentBuilder
    func boardToolbar(board: Dashboard) -> some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(PanelKind.allCases) { kind in
                    Button {
                        if let panel = model.store.addPanel(kind: kind, to: board.id) {
                            model.isEditing = true
                            model.inspectedPanelID = panel.id
                        }
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                    }
                }
            } label: {
                Label("Add Panel", systemImage: "plus.rectangle.on.rectangle")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.isEditing) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .toggleStyle(.button)
            .keyboardShortcut("e", modifiers: .command)
        }
        if model.isEditing {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.store.undo()
                } label: {
                    Label(model.store.undoActionName.map { "Undo \($0)" } ?? "Undo",
                          systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.store.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            }
        }
        ToolbarItem(placement: .automatic) {
            // The original app's "Send" feature, modernized: share the board
            // as a rendered image or as JSON.
            Menu {
                ShareLink(item: BoardPoster(board: board, records: model.snapshots.records),
                          preview: SharePreview("\(board.name) board")) {
                    Label("Share as Image", systemImage: "photo")
                }
                ShareLink(item: boardJSON(board),
                          preview: SharePreview(board.name)) {
                    Label("Share as JSON", systemImage: "curlybraces")
                }
            } label: {
                Label("Share Board", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItem(placement: .automatic) {
            BridgeStatusLabel(model: model)
        }
    }

    func boardJSON(_ board: Dashboard) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(board) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Compact indicator for bridge connectivity (client side) or the running
/// server (macOS).
struct BridgeStatusLabel: View {
    let model: AppModel

    var body: some View {
        #if os(macOS)
        HStack(spacing: 5) {
            Circle()
                .fill(model.bridgeServer.isRunning ? SBTheme.good : SBTheme.textSecondary)
                .frame(width: 7, height: 7)
            Text(model.bridgeServer.isRunning
                 ? "Bridge · \(model.bridgeServer.subscriberCount)"
                 : "Bridge off")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
        #else
        switch model.bridgeClient.connectionState {
        case .connected(let name):
            Label(name, systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(SBTheme.good)
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .disconnected:
            EmptyView()
        }
        #endif
    }
}
#endif

// MARK: - tvOS

#if os(tvOS)
struct TVRootView: View {
    @Bindable var model: AppModel
    /// 0 = off; otherwise seconds between automatic board switches.
    @AppStorage("sb.autoCycleSeconds") private var autoCycleSeconds = 0

    var body: some View {
        TabView(selection: Binding(
            get: { model.store.selectedDashboardID ?? model.store.dashboards.first?.id },
            set: { model.store.selectedDashboardID = $0 })) {
            ForEach(model.store.dashboards) { board in
                BoardView(model: model, dashboardID: board.id)
                    .tabItem { Text(board.name) }
                    .tag(Optional(board.id))
            }
            tvSettings
                .tabItem { Image(systemName: "gearshape") }
                .tag(Optional<Dashboard.ID>.none)
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottomTrailing) {
            if case .connected(let name) = model.bridgeClient.connectionState {
                Label(name, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(SBTheme.textSecondary)
                    .padding(8)
            }
        }
        .task(id: autoCycleSeconds) {
            guard autoCycleSeconds > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoCycleSeconds))
                guard !Task.isCancelled else { return }
                advanceBoard()
            }
        }
    }

    private func advanceBoard() {
        let boards = model.store.dashboards
        guard boards.count > 1 else { return }
        guard let current = model.store.selectedDashboardID,
              let index = boards.firstIndex(where: { $0.id == current }) else {
            model.store.selectedDashboardID = boards.first?.id
            return
        }
        model.store.selectedDashboardID = boards[(index + 1) % boards.count].id
    }

    private var tvSettings: some View {
        VStack(spacing: 24) {
            Text("Settings")
                .font(.title2.bold())
            Picker("Cycle dashboards", selection: $autoCycleSeconds) {
                Text("Off").tag(0)
                Text("Every 30 seconds").tag(30)
                Text("Every minute").tag(60)
                Text("Every 5 minutes").tag(300)
            }
            .pickerStyle(.inline)
            .frame(maxWidth: 700)
            Text("Dashboards and their data sync from your other devices via iCloud, and live data arrives from the Mac bridge.")
                .font(.callout)
                .foregroundStyle(SBTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SBTheme.background.ignoresSafeArea())
    }
}
#endif
