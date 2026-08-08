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
    @State private var showsBoardAppearance = false
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
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
        .sheet(isPresented: $showsBoardAppearance) {
            if let board = model.store.selectedDashboard {
                BoardAppearanceView(model: model, dashboardID: board.id)
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
                        Button("Duplicate") {
                            model.store.duplicate(id: board.id)
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
                        Button {
                            model.store.add(.clockFaces())
                        } label: {
                            Label("Clock Faces", systemImage: "clock.badge")
                        }
                        Button {
                            model.store.add(.glassGallery())
                        } label: {
                            Label("Glass", systemImage: "square.on.square.dashed")
                        }
                        Button {
                            model.store.add(.homeBoard())
                        } label: {
                            Label("Home", systemImage: "house.fill")
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
            Group {
                // Arranging another screen takes over the detail area rather
                // than opening a sheet, so the board gets the whole window.
                if let target = model.layoutTarget {
                    DeviceLayoutEditorView(model: model, dashboardID: board.id,
                                           device: target)
                } else {
                    BoardView(model: model, dashboardID: board.id)
                }
            }
            .navigationTitle(board.name)
            #if os(macOS)
            .navigationSubtitle(model.layoutTarget.map { "Arranging for \($0.displayName)" } ?? "")
            #endif
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

    // Deliberately no sidebar button here: NavigationSplitView puts one in the
    // sidebar's own toolbar on macOS, and adding a second left two identical
    // controls side by side in the title bar.
    @ToolbarContentBuilder
    func boardToolbar(board: Dashboard) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(PanelKind.allCases) { kind in
                    Button {
                        if let panel = model.store.addPanel(kind: kind, to: board.id) {
                            model.isEditing = true
                            // Selected as well as inspected: a board with no
                            // room left takes the new panel on top of its
                            // neighbours, and selection is what marks it out
                            // and keeps it above them while it's dragged home.
                            model.selectedPanelID = panel.id
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
            Button {
                showsBoardAppearance = true
            } label: {
                Label("Board Appearance", systemImage: "paintpalette")
            }
            .help("Theme, wallpaper and spacing for this board")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.isEditing) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .toggleStyle(.button)
            .keyboardShortcut("e", modifiers: .command)
        }
        // Which screen the window is arranging, sitting beside Edit because it
        // decides where every edit lands.
        ToolbarItem(placement: .primaryAction) {
            ScreenTargetMenu(model: model)
        }
        if model.layoutTarget != nil {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showsLayoutInspector.toggle()
                } label: {
                    Label("Layout Options", systemImage: "sidebar.right")
                }
                .help("Show or hide grid, panel and overscan options")
            }
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
                    Label("Share as JSON — Credentials Omitted", systemImage: "curlybraces")
                }
            } label: {
                Label("Share Board", systemImage: "square.and.arrow.up")
            }
        }
        ToolbarItem(placement: .automatic) {
            CloudStatusMenu(model: model)
        }
        ToolbarItem(placement: .automatic) {
            BridgeStatusLabel(model: model)
        }
    }

    func boardJSON(_ board: Dashboard) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(board.redactedForExternalTransfer()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Chooses which screen the window shows and edits: this device's own live
/// board, or another screen's arrangement of the same board.
struct ScreenTargetMenu: View {
    @Bindable var model: AppModel

    private var current: SBDeviceClass { .current }

    var body: some View {
        Menu {
            Button {
                model.layoutTarget = nil
            } label: {
                Label("This \(current.displayName)",
                      systemImage: model.layoutTarget == nil ? "checkmark" : current.symbolName)
            }
            Section("Arrange For") {
                // Grouped by hardware, with a submenu for the screens that
                // turn: an iPhone lying on its side is a different shape and
                // carries a different arrangement, but it is still an iPhone.
                ForEach(offeredFamilies) { family in
                    if family.layouts.count > 1 {
                        Menu {
                            ForEach(family.layouts) { device in
                                Button {
                                    arrange(device)
                                } label: {
                                    Label(device.orientation.displayName,
                                          systemImage: model.layoutTarget == device
                                              ? "checkmark" : device.symbolName)
                                }
                            }
                        } label: {
                            Label(family.displayName,
                                  systemImage: family.primaryLayout.symbolName)
                        }
                    } else {
                        Button {
                            arrange(family.primaryLayout)
                        } label: {
                            Label(label(for: family),
                                  systemImage: model.layoutTarget == family.primaryLayout
                                      ? "checkmark" : family.primaryLayout.symbolName)
                        }
                    }
                }
            }
            // Nothing else in this menu can be absent, so a wearer who expected
            // the glasses and doesn't see them needs to be told where the switch
            // is rather than left wondering.
            if !model.glassesLink.isOffered {
                Section {
                    Toggle("Arrange for Smart Glasses", isOn: Binding(
                        get: { model.glassesLink.alwaysOffered },
                        set: { model.glassesLink.alwaysOffered = $0 }))
                }
            }
        } label: {
            Label(model.layoutTarget?.displayName ?? "This \(current.displayName)",
                  systemImage: (model.layoutTarget ?? current).symbolName)
        }
        .labelStyle(.titleAndIcon)
        .help("Choose the screen this window arranges: Apple TV, iPad, iPhone, Mac, Watch — or a linked pair of smart glasses — and which way it is turned")
    }

    /// Every screen worth offering. The glasses are the one entry that can be
    /// absent: Status Board doesn't run on them, so the screen only means
    /// something while a SybilSight is linked to draw it.
    private var offeredFamilies: [SBDeviceFamily] {
        SBDeviceFamily.allCases.filter { !$0.requiresLink || model.glassesLink.isOffered }
    }

    /// The glasses are named after the pair that's linked, when one is, so the
    /// menu says "Kalani's iPhone" rather than a generic label the wearer has to
    /// match up to hardware themselves.
    private func label(for family: SBDeviceFamily) -> String {
        guard family == .glasses, model.glassesLink.isLive else { return family.displayName }
        return "\(family.displayName) — \(model.glassesLink.displayName)"
    }

    /// Picking a screen is asking to arrange it, so drop straight into edit mode.
    private func arrange(_ device: SBDeviceClass) {
        model.layoutTarget = device
        model.isEditing = true
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

/// iCloud state, and the button that retries it.
///
/// Apple TV had this from the start and the authoring platforms didn't, which
/// made a sync failure here completely mute: `CloudSyncEngine` records exactly
/// why nothing arrived in `statusDetail`, but nothing on iPhone, iPad or Mac
/// ever read it, and `syncNow()` had no caller outside the TV menu. A phone
/// showing the starter board could not say that it had never reached iCloud,
/// and gave you no way to ask it to try again.
struct CloudStatusMenu: View {
    let model: AppModel
    @State private var isChecking = false

    private var symbol: String {
        if isChecking { return "arrow.clockwise.icloud" }
        return model.sync.isHealthy ? "checkmark.icloud" : "exclamationmark.icloud"
    }

    var body: some View {
        Menu {
            Section("iCloud") {
                Text(model.sync.statusDetail)
            }
            Button {
                guard !isChecking else { return }
                isChecking = true
                Task {
                    await model.sync.syncNow()
                    isChecking = false
                }
            } label: {
                Label(isChecking ? "Checking…" : "Sync Now",
                      systemImage: "arrow.clockwise")
            }
            .disabled(isChecking)
        } label: {
            Label("iCloud", systemImage: symbol)
                .foregroundStyle(model.sync.isHealthy ? SBTheme.textSecondary : SBTheme.warn)
        }
        .help(model.sync.statusDetail)
    }
}
#endif

// MARK: - tvOS

#if os(tvOS)
/// Apple TV is a display first: the board fills the screen with no permanent
/// chrome. Swiping down on the remote brings up the board picker and settings;
/// the Menu button dismisses them again.
struct TVRootView: View {
    @Bindable var model: AppModel
    /// 0 = off; otherwise seconds between automatic board switches.
    @AppStorage("sb.autoCycleSeconds") private var autoCycleSeconds = 0
    /// The board this Apple TV shows, remembered across launches. Deliberately
    /// device-local rather than synced: each screen in the house picks its own
    /// board out of the shared iCloud set.
    @AppStorage("sb.tv.boardID") private var pinnedBoardID = ""
    /// Televisions crop the edges of the picture. Off by default, the board
    /// stays inside the title-safe area so no panel can be lost to overscan;
    /// on a screen that shows every pixel, turn it on to reclaim the margins.
    @AppStorage("sb.tv.fillsScreen") private var fillsScreen = false

    @State private var showsMenu = false
    @State private var showsHint = true
    /// The pinned board may not have arrived from iCloud yet, so restoring it
    /// keeps retrying as boards land — but only until it succeeds once, so it
    /// never fights the auto-cycle afterwards.
    @State private var hasRestoredPinnedBoard = false
    @FocusState private var boardHasFocus: Bool

    private var selectedID: Dashboard.ID? {
        model.store.selectedDashboardID ?? model.store.dashboards.first?.id
    }

    var body: some View {
        // A plain Button is what reliably takes focus on tvOS, and a focused
        // view is what receives move commands at all. It also means the menu
        // can still be reached by clicking the touchpad, so the settings can
        // never become unreachable if a swipe is missed.
        Button {
            showsMenu = true
        } label: {
            ZStack {
                SBTheme.background
                if let id = selectedID {
                    BoardView(model: model, dashboardID: id)
                } else {
                    waitingForBoards
                }
            }
        }
        .buttonStyle(.plain)
        // Fill the panel out to whatever the TV will actually show: the whole
        // screen when the user says the set has no overscan, otherwise the
        // title-safe area.
        .ignoresSafeArea(edges: fillsScreen ? .all : [])
        .background(SBTheme.background.ignoresSafeArea())
        .focused($boardHasFocus)
        .onMoveCommand { direction in
            if direction == .down { showsMenu = true }
        }
        .onAppear {
            boardHasFocus = true
            restorePinnedBoard()
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { showsHint = false }
            }
        }
        // Boards arrive from iCloud whenever they arrive; catch the pinned one
        // the moment it shows up.
        .onChange(of: model.store.dashboards.map(\.id)) { _, _ in
            restorePinnedBoard()
        }
        .overlay(alignment: .bottom) {
            if showsHint && !showsMenu {
                Label("Swipe down or click for boards and settings",
                      systemImage: "chevron.down")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(SBTheme.textPrimary)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 18)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        // The board is the picture; nothing permanent sits on top of it. Which
        // Mac this Apple TV is connected to belongs in the menu and in the
        // empty state, not burned into the corner of every board.
        .sheet(isPresented: $showsMenu) {
            TVMenuView(model: model,
                       autoCycleSeconds: $autoCycleSeconds,
                       fillsScreen: $fillsScreen,
                       selectedBoardID: selectedID,
                       onSelect: pin)
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

    /// The empty state carries the diagnosis, because this screen is the only
    /// place the user will ever look. Sitting on a bare "Waiting for Boards"
    /// while iCloud reported a real error is what made this look unfixable.
    private var waitingForBoards: some View {
        VStack(spacing: 20) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(SBTheme.accent)
            Text("Waiting for Boards")
                .font(SBTheme.titleFont(size: 44))
                .foregroundStyle(SBTheme.textPrimary)
            Text("Boards you build on your iPhone, iPad or Mac appear here — over iCloud, or straight from a Mac running Status Board on this network.")
                .font(.system(size: 26, design: .rounded))
                .foregroundStyle(SBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)

            VStack(spacing: 10) {
                Label(model.sync.statusDetail, systemImage: "icloud")
                    .foregroundStyle(model.sync.isHealthy ? SBTheme.textSecondary : SBTheme.warn)
                Label(bridgeDetail, systemImage: "laptopcomputer")
                    .foregroundStyle(SBTheme.textSecondary)
            }
            .font(.system(size: 22, design: .rounded))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 900)
            .padding(.top, 12)
        }
    }

    private var bridgeDetail: String {
        switch model.bridgeClient.connectionState {
        case .connected(let name):
            return "Connected to \(name) — open Status Board there to send boards"
        case .connecting:
            return "Connecting to a Mac on this network…"
        case .disconnected:
            return "No Mac found on this network"
        }
    }

    /// Shows a board and remembers it as this Apple TV's choice.
    private func pin(_ id: Dashboard.ID) {
        model.store.selectedDashboardID = id
        pinnedBoardID = id.uuidString
        hasRestoredPinnedBoard = true
    }

    private func restorePinnedBoard() {
        guard !hasRestoredPinnedBoard else { return }
        guard let pinned = UUID(uuidString: pinnedBoardID) else {
            hasRestoredPinnedBoard = true
            return
        }
        // Still not synced down; try again on the next arrival.
        guard model.store.dashboard(id: pinned) != nil else { return }
        model.store.selectedDashboardID = pinned
        hasRestoredPinnedBoard = true
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
}

/// Board picker and settings, reached by swiping down. Dismissed with Menu.
///
/// Everything here is built for a ten-foot read: one full-width row per choice,
/// large type, and a single scrolling column, so nothing has to be squeezed in
/// beside anything else.
struct TVMenuView: View {
    @Bindable var model: AppModel
    @Binding var autoCycleSeconds: Int
    @Binding var fillsScreen: Bool
    let selectedBoardID: Dashboard.ID?
    let onSelect: (Dashboard.ID) -> Void

    @State private var isCheckingCloud = false
    @Environment(\.dismiss) private var dismiss

    private static let cycleOptions: [(seconds: Int, title: String)] = [
        (0, "Off"),
        (30, "Every 30 Seconds"),
        (60, "Every Minute"),
        (300, "Every 5 Minutes"),
        (900, "Every 15 Minutes"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 52) {
                header
                boardsSection
                schoolSection
                bridgeAccessSection
                displaySection
                cycleSection
                footer
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 50)
        }
        .background(SBTheme.background.ignoresSafeArea())
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status Board")
                .font(SBTheme.titleFont(size: 58))
                .foregroundStyle(SBTheme.textPrimary)
            Text(currentBoardName.map { "Showing \($0)" } ?? "No board selected")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundStyle(SBTheme.accent)
                .lineLimit(1)
        }
    }

    private var boardsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Boards", detail: cloudSummary, isWarning: cloudIsUnavailable)
            ForEach(model.store.dashboards) { board in
                TVMenuRow(title: board.name,
                          subtitle: subtitle(for: board),
                          isSelected: board.id == selectedBoardID) {
                    onSelect(board.id)
                    dismiss()
                }
            }
            TVMenuRow(title: isCheckingCloud ? "Checking iCloud…" : "Check iCloud for Boards",
                      subtitle: "Fetch boards added or changed on your other devices",
                      systemImage: "arrow.clockwise.icloud",
                      isBusy: isCheckingCloud) {
                Task {
                    isCheckingCloud = true
                    await model.sync.syncNow()
                    isCheckingCloud = false
                }
            }
        }
    }

    /// Where the K12 sign-in came from — shown only when a board here actually
    /// has a class panel on it.
    ///
    /// An Apple TV cannot sign in to the portal: that takes a web view, and
    /// tvOS has none. So it borrows one, either through your private iCloud
    /// database or from a Mac on this network. When neither has arrived, this
    /// is the only place that can say so — the panel itself has room for one
    /// line of error and no way to explain it.
    @ViewBuilder
    private var schoolSection: some View {
        if model.store.allPanels.contains(where: { $0.kind == .k12schedule || $0.kind == .schedule }) {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Class Schedule", detail: schoolDetail,
                              isWarning: !K12Session.shared.isSignedIn
                                  && !model.bridgeClient.isConnected)
            }
        }
    }

    private var schoolDetail: String {
        if K12Session.shared.isSignedIn {
            return "Signed in to \(K12Session.shared.portal) — the sign-in came from another device through iCloud."
        }
        if case .connected(let name) = model.bridgeClient.connectionState {
            return "No sign-in of its own; asking \(name) for the schedule instead."
        }
        return "Sign in to K12 on your iPhone or Mac. This Apple TV can't show the portal's sign-in page, so it uses the session from there — over iCloud, or from a Mac on this network."
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Screen Fit",
                          detail: "Use Fit Inside TV Edges if panels are cut off")
            TVMenuRow(title: "Fit Inside TV Edges",
                      subtitle: "Keeps every panel clear of the edges your TV may crop",
                      isSelected: !fillsScreen) {
                fillsScreen = false
            }
            TVMenuRow(title: "Fill the Whole Screen",
                      subtitle: "Edge to edge, for screens that show every pixel",
                      isSelected: fillsScreen) {
                fillsScreen = true
            }
        }
    }

    private var bridgeAccessSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Mac Bridge Access",
                          detail: "Only needed when the Mac bridge is protected with a token")
            SecureField("Bridge token", text: Binding(
                get: { model.bridgeClient.token },
                set: { model.bridgeClient.token = $0 }))
                .textContentType(.password)
        }
    }

    private var cycleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Cycle Boards",
                          detail: "Rotate through every board automatically")
            ForEach(Self.cycleOptions, id: \.seconds) { option in
                TVMenuRow(title: option.title,
                          isSelected: autoCycleSeconds == option.seconds) {
                    autoCycleSeconds = option.seconds
                }
            }
        }
    }

    private var footer: some View {
        Text("Boards and their panel data sync from your iPhone, iPad and Mac over iCloud, and live values arrive from the Mac bridge. Arrange this board for the TV by choosing Apple TV from the screen menu on your Mac, iPad or iPhone.")
            .font(.system(size: 24, design: .rounded))
            .foregroundStyle(SBTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    private func sectionHeader(_ title: String, detail: String?,
                               isWarning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(SBTheme.titleFont(size: 24))
                .foregroundStyle(SBTheme.textSecondary)
                .tracking(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 24, design: .rounded))
                    .foregroundStyle(isWarning ? SBTheme.warn : SBTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Text

    private var currentBoardName: String? {
        guard let selectedBoardID else { return nil }
        return model.store.dashboard(id: selectedBoardID)?.name
    }

    private var cloudIsUnavailable: Bool { !model.sync.isHealthy }

    private var cloudSummary: String {
        let cloud = model.sync.statusDetail
        guard case .connected(let name) = model.bridgeClient.connectionState else {
            return cloud
        }
        return "\(cloud)\nAlso receiving boards from \(name)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func subtitle(for board: Dashboard) -> String {
        let shown = board.panels(for: .tv).count
        let total = board.panels.count
        let panels = shown == total
            ? "\(total) panel\(total == 1 ? "" : "s")"
            : "\(shown) of \(total) panels shown here"
        let updated = Self.relative.localizedString(for: board.modifiedAt, relativeTo: Date())
        return "\(panels) · Updated \(updated)"
    }
}

/// One full-width, focusable choice. Rows invert to a light background when
/// focused so the label stays legible from across the room, and titles wrap
/// rather than truncate.
private struct TVMenuRow: View {
    var title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected: Bool = false
    var isBusy: Bool = false
    var action: () -> Void

    @FocusState private var isFocused: Bool

    private var icon: String {
        systemImage ?? (isSelected ? "checkmark.circle.fill" : "circle")
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(iconColor)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 24, design: .rounded))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .foregroundStyle(isFocused ? SBTheme.background : SBTheme.textPrimary)
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? SBTheme.textPrimary : SBTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected && !isFocused ? SBTheme.accent : .clear,
                                  lineWidth: 3)
            )
            .scaleEffect(isFocused ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var iconColor: Color {
        if isFocused { return isSelected ? SBTheme.background : SBTheme.background.opacity(0.5) }
        return isSelected ? SBTheme.accent : SBTheme.textSecondary
    }

    private var secondaryColor: Color {
        isFocused ? SBTheme.background.opacity(0.7) : SBTheme.textSecondary
    }
}
#endif
