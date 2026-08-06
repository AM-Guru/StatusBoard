#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// Configuration sheet for a panel. Edits a draft and commits on Save.
public struct PanelInspectorView: View {
    let model: AppModel
    let dashboardID: Dashboard.ID
    /// Kept so unsaved edits can be detected before the sheet is swiped away.
    private let original: Panel

    @State private var draft: Panel
    @State private var showingRegionPicker = false
    @State private var loginUsername = ""
    @State private var loginPassword = ""
    @State private var savedCredentialHost: String?
    @State private var showingK12SignIn = false
    @Environment(\.dismiss) private var dismiss

    public init(model: AppModel, panel: Panel, dashboardID: Dashboard.ID) {
        self.model = model
        self.dashboardID = dashboardID
        self.original = panel
        self._draft = State(initialValue: panel)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Panel") {
                    TextField("Title", text: $draft.title)
                    if draft.kind.isFetched {
                        Picker("Refresh", selection: $draft.settings.refreshSeconds) {
                            Text("30 seconds").tag(30.0)
                            Text("1 minute").tag(60.0)
                            Text("5 minutes").tag(300.0)
                            Text("15 minutes").tag(900.0)
                            Text("1 hour").tag(3600.0)
                        }
                    }
                }
                kindSections
                appearanceSection
                alertSection
                liveActivitySection
            }
            .formStyle(.grouped)
            .navigationTitle(draft.kind.displayName)
            // Edits only reach the panel through Save. Without this, swiping
            // the sheet down throws away everything just typed — which reads
            // as "the setting won't change".
            .interactiveDismissDisabled(draft != original)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.store.updatePanel(draft, in: dashboardID)
                        model.engine.refreshNow(panel: draft)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
        .sheet(isPresented: $showingK12SignIn) {
            K12SignInView(portal: draft.settings.connector?.projectURL ?? K12Session.defaultPortal) {
                model.engine.refreshNow(panel: draft)
            }
        }
        .sheet(isPresented: $showingRegionPicker) {
            WebClipPickerView(urlString: draft.settings.url ?? "",
                              selector: draft.settings.webClipSelector,
                              hideSelectors: draft.settings.webClipHideSelectors,
                              blocksAds: draft.settings.webClipBlocksAds) { selector, hides, blocksAds, url in
                draft.settings.webClipSelector = selector
                draft.settings.webClipHideSelectors = hides
                draft.settings.webClipBlocksAds = blocksAds
                if !url.isEmpty { draft.settings.url = url }
            }
        }
    }

    @ViewBuilder
    private var kindSections: some View {
        switch draft.kind {
        case .clock:
            Section("Clock") {
                TextField("Time zone ID (e.g. Europe/Paris)",
                          text: optionalString($draft.settings.timeZoneID))
                Toggle("Show seconds", isOn: $draft.settings.showsSeconds)
            }

        case .weather:
            Section("Location") {
                TextField("Name", text: optionalString($draft.settings.locationName))
                TextField("Latitude", text: optionalDouble($draft.settings.latitude))
                TextField("Longitude", text: optionalDouble($draft.settings.longitude))
            }

        case .countdown:
            Section("Countdown") {
                DatePicker("Target date",
                           selection: Binding(
                               get: { draft.settings.targetDate ?? Date().addingTimeInterval(86400) },
                               set: { draft.settings.targetDate = $0 }))
            }

        case .text:
            Section("Text") {
                TextEditor(text: Binding(
                    get: { draft.settings.text ?? "" },
                    set: { draft.settings.text = $0.isEmpty ? nil : $0 }))
                    .frame(minHeight: 90)
                    .font(.body)
            }

        case .feed:
            Section("Feed") {
                TextField("RSS / Atom URL", text: optionalString($draft.settings.url))
                    .autocorrectionOff()
                Picker("Display", selection: $draft.settings.listDisplay) {
                    ForEach(ListDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

        case .calendar:
            Section("Calendar") {
                Stepper("Next \(draft.settings.calendarDaysAhead) days",
                        value: $draft.settings.calendarDaysAhead, in: 1...60)
                Picker("Display", selection: $draft.settings.listDisplay) {
                    ForEach(ListDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Events come from this device's calendars. Apple TV can't access calendars.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .webClip:
            Section("Web Clip") {
                TextField("Page URL", text: optionalString($draft.settings.url))
                    .autocorrectionOff()
                Button {
                    showingRegionPicker = true
                } label: {
                    Label(draft.settings.webClipSelector == nil
                          ? "Choose Region to Show…"
                          : "Change Selected Region…",
                          systemImage: "viewfinder")
                }
                .disabled((draft.settings.url ?? "").isEmpty)
                if let selector = draft.settings.webClipSelector {
                    LabeledContent("Region") {
                        Text(selector)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Show Full Page Again", role: .destructive) {
                        draft.settings.webClipSelector = nil
                    }
                }
                if !draft.settings.webClipHideSelectors.isEmpty {
                    LabeledContent("Hidden elements") {
                        Text("\(draft.settings.webClipHideSelectors.count)")
                    }
                    Button("Unhide All", role: .destructive) {
                        draft.settings.webClipHideSelectors.removeAll()
                    }
                }
                Toggle("Block ads and trackers", isOn: $draft.settings.webClipBlocksAds)
                LabeledContent("Zoom") {
                    Slider(value: $draft.settings.webClipZoom, in: 0.4...2, step: 0.1)
                }
                Text("The clip re-applies after every scheduled refresh. On Apple TV, the Mac bridge renders and crops the region.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            signInSection

        case .graph:
            Section("Data Source") {
                TextField("Bridge key (e.g. cpu.history)",
                          text: optionalString($draft.settings.bridgeKey))
                TextField("…or JSON URL", text: optionalString($draft.settings.url))
                    .autocorrectionOff()
                TextField("Series path (e.g. data.items[*])",
                          text: optionalString($draft.settings.seriesPath))
                TextField("Point value path (e.g. price)",
                          text: optionalString($draft.settings.pointValuePath))
                TextField("Point label path (e.g. day)",
                          text: optionalString($draft.settings.pointLabelPath))
                TextField("Unit", text: optionalString($draft.settings.unit))
            }
            Section("Style") {
                Picker("Chart style", selection: $draft.settings.chartStyle) {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                TextField("Baseline (optional)", text: optionalDouble($draft.settings.chartBase))
            }

        case .progress:
            Section("Data Source") {
                TextField("Bridge key (e.g. build)",
                          text: optionalString($draft.settings.bridgeKey))
                TextField("…or JSON URL", text: optionalString($draft.settings.url))
                    .autocorrectionOff()
                TextField("Value path (e.g. data.percent)",
                          text: optionalString($draft.settings.valuePath))
                TextField("Total (blank = value is 0–100)",
                          text: optionalDouble($draft.settings.progressTotal))
            }
            Section("Style") {
                Picker("Format", selection: $draft.settings.progressFormat) {
                    ForEach(ProgressFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
            }

        case .image:
            Section("Image") {
                TextField("Image URL", text: optionalString($draft.settings.url))
                    .autocorrectionOff()
                TextField("Filters (e.g. sepia:70,blur:20)",
                          text: optionalString($draft.settings.imageFilter))
                Text("Filters: sepia, blur, pixelate, grayscale, invert — chain with commas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .table:
            Section("Table") {
                TextField("JSON or CSV URL", text: optionalString($draft.settings.url))
                    .autocorrectionOff()
                TextField("Rows path (optional, e.g. data.rows)",
                          text: optionalString($draft.settings.seriesPath))
                Toggle("First row is a header", isOn: $draft.settings.tableHasHeader)
                Toggle("Zebra striping", isOn: $draft.settings.tableZebra)
                Toggle("Color status words", isOn: $draft.settings.tableStatusColoring)
            }

        case .status:
            Section("Services") {
                ForEach($draft.settings.statusTargets) { $target in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $target.name)
                        TextField("https://…", text: $target.url)
                            .autocorrectionOff()
                            .font(.callout)
                    }
                }
                .onDelete { draft.settings.statusTargets.remove(atOffsets: $0) }
                Button("Add Service") {
                    draft.settings.statusTargets.append(
                        StatusTarget(name: "Service", url: "https://"))
                }
            }

        case .bridge:
            Section("Bridge") {
                TextField("Key (e.g. deploys)", text: optionalString($draft.settings.bridgeKey))
                Text("Push data from any script:\ncurl -X POST http://<mac>:7311/api/push -d '{\"key\":\"\(draft.settings.bridgeKey ?? "deploys")\",\"text\":\"hello\"}'")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .mcp:
            mcpSections

        case .github, .appStoreConnect, .supabase, .logs, .canvas, .k12schedule:
            connectorSections

        case .grades, .assignments:
            Section(draft.kind == .grades ? "Grades" : "Assignments") {
                TextField("Your Canvas address, e.g. learn2.k12.com",
                          text: optionalString(canvasConnector.projectURL))
                    .autocorrectionOff()
                SecureField("Access token", text: optionalString(canvasConnector.token))
                Text(draft.kind == .grades
                     ? "Shows every active course with its current score."
                     : "Due today and late work. Anything finished at 100%, or handed in and waiting on a grade, is hidden. Graded below 100% moves to Re-Do.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            aliasSection

        case .schedule:
            Section("Schedule") {
                TextField("Portal URL", text: optionalString(canvasConnector.projectURL))
                    .autocorrectionOff()
                    .onAppear {
                        if canvasConnector.wrappedValue.projectURL == nil {
                            canvasConnector.wrappedValue.projectURL = K12Session.defaultPortal
                        }
                    }
                LabeledContent("Sign-in") {
                    switch K12Session.shared.state {
                    case .signedIn:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(SBTheme.good)
                    case .expired:
                        Label("Expired", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SBTheme.warn)
                    case .signedOut:
                        Text("Not signed in").foregroundStyle(.secondary)
                    }
                }
                Button(K12Session.shared.isSignedIn ? "Sign In Again…" : "Sign In to K12…") {
                    showingK12SignIn = true
                }
                Text("Shows the classes still to come today, with a live countdown. Tap one to open it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            aliasSection

        case .health:
            Section("Health") {
                Picker("Metric", selection: $draft.settings.healthMetric) {
                    ForEach(HealthMetric.allCases, id: \.self) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                Text("Reads from Health on this device. Other devices see the value via iCloud sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shared plumbing for the external-service connector kinds.
    @ViewBuilder
    private var connectorSections: some View {
        let connector = Binding<ConnectorConfig>(
            get: { draft.settings.connector ?? ConnectorConfig() },
            set: { draft.settings.connector = $0 })

        switch draft.kind {
        case .github:
            Section("GitHub") {
                TextField("Repository (owner/name)", text: optionalString(connector.repo))
                    .autocorrectionOff()
                SecureField("Token (optional for public repos)",
                            text: optionalString(connector.token))
                Picker("Show", selection: connector.mode) {
                    Text("Workflow Runs").tag("runs")
                    Text("Open Issues").tag("issues")
                    Text("Open Pull Requests").tag("prs")
                    Text("Latest Release").tag("releases")
                    Text("Stars").tag("stars")
                }
                .onAppear { if connector.wrappedValue.mode.isEmpty { connector.wrappedValue.mode = "runs" } }
            }

        case .appStoreConnect:
            Section("App Store Connect API Key") {
                TextField("Key ID", text: optionalString(connector.keyID))
                    .autocorrectionOff()
                TextField("Issuer ID", text: optionalString(connector.issuerID))
                    .autocorrectionOff()
                TextEditor(text: Binding(
                    get: { connector.wrappedValue.privateKeyPEM ?? "" },
                    set: { connector.wrappedValue.privateKeyPEM = $0.isEmpty ? nil : $0 }))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(minHeight: 70)
                Text("Paste the contents of your .p8 key file. Keys sync only through your private iCloud database.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Query") {
                Picker("Show", selection: connector.mode) {
                    Text("Apps").tag("apps")
                    Text("TestFlight Builds").tag("builds")
                    Text("Customer Reviews").tag("reviews")
                }
                .onAppear { if connector.wrappedValue.mode.isEmpty { connector.wrappedValue.mode = "builds" } }
                if connector.wrappedValue.mode == "reviews" {
                    TextField("Numeric app ID", text: optionalString(connector.query))
                        .autocorrectionOff()
                }
            }

        case .supabase:
            Section("Supabase") {
                Picker("Mode", selection: connector.mode) {
                    Text("Table Query").tag("select")
                    Text("SQL").tag("sql")
                }
                .pickerStyle(.segmented)
                .onAppear { if connector.wrappedValue.mode.isEmpty { connector.wrappedValue.mode = "select" } }
                if connector.wrappedValue.mode == "sql" {
                    TextField("Project ref (e.g. abcdefghijklm)", text: optionalString(connector.projectURL))
                        .autocorrectionOff()
                    SecureField("Personal access token", text: optionalString(connector.token))
                    TextEditor(text: Binding(
                        get: { connector.wrappedValue.query ?? "" },
                        set: { connector.wrappedValue.query = $0.isEmpty ? nil : $0 }))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 60)
                    Text("Runs through the Supabase management API. One value renders big; label+number rows render as a chart; anything else becomes a table.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Project URL (https://xyz.supabase.co)",
                              text: optionalString(connector.projectURL))
                        .autocorrectionOff()
                    SecureField("API key (anon or service role)", text: optionalString(connector.token))
                    TextField("Query (e.g. todos?select=*&limit=20)",
                              text: optionalString(connector.query))
                        .autocorrectionOff()
                }
            }

        case .canvas:
            Section("Canvas") {
                TextField("Your Canvas address, e.g. learn2.k12.com",
                          text: optionalString(connector.projectURL))
                    .autocorrectionOff()
                SecureField("Access token", text: optionalString(connector.token))
                Picker("Show", selection: connector.mode) {
                    ForEach(CanvasSource.Mode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .onAppear {
                    if connector.wrappedValue.mode.isEmpty {
                        connector.wrappedValue.mode = CanvasSource.Mode.dueToday.rawValue
                    }
                }
                Text("Use your school's own Canvas address — for K12/Stride that is learn2.k12.com, not school.instructure.com. Create a token at that address under Account → Settings → “+ New Access Token”. If your school has disabled tokens, use a Schedule panel and sign in there instead. The token is stored in your dashboard, which syncs only through your private iCloud database.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .k12schedule:
            Section("K12 Class Schedule") {
                TextField("Portal URL", text: optionalString(connector.projectURL))
                    .autocorrectionOff()
                Picker("Show", selection: connector.mode) {
                    ForEach(K12OLSSource.Mode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .onAppear {
                    if connector.wrappedValue.projectURL == nil {
                        connector.wrappedValue.projectURL = K12Session.defaultPortal
                    }
                    if connector.wrappedValue.mode.isEmpty {
                        connector.wrappedValue.mode = K12OLSSource.Mode.todayClasses.rawValue
                    }
                }
                LabeledContent("Sign-in") {
                    switch K12Session.shared.state {
                    case .signedIn:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(SBTheme.good)
                    case .expired:
                        Label("Expired", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SBTheme.warn)
                    case .signedOut:
                        Text("Not signed in").foregroundStyle(.secondary)
                    }
                }
                Button(K12Session.shared.isSignedIn ? "Sign In Again…" : "Sign In to K12…") {
                    showingK12SignIn = true
                }
                if K12Session.shared.isSignedIn {
                    Button("Sign Out", role: .destructive) { K12Session.shared.signOut() }
                }
                Text("Class times live in the K12 portal, not Canvas. You sign in once here; afterwards the panel calls the portal's API directly — no embedded web page, so it stays fast and works in widgets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .logs:
            Section("Access Log") {
                TextField("Log URL (Apache/nginx combined format)",
                          text: optionalString(connector.query))
                    .autocorrectionOff()
                Picker("Show", selection: connector.mode) {
                    Text("Traffic (req/hour)").tag("traffic")
                    Text("Top Paths").tag("paths")
                    Text("Status Mix").tag("status")
                }
                .onAppear { if connector.wrappedValue.mode.isEmpty { connector.wrappedValue.mode = "traffic" } }
                Text("For local log files, serve them via the Mac bridge or any static file server. Streaming push also works: tail -f access.log | sbctl pipe --key weblog")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var mcpSections: some View {
        let mcpBinding = Binding<MCPPanelConfig>(
            get: {
                draft.settings.mcp ?? MCPPanelConfig(
                    server: MCPServerConfig(transport: .http), tool: "")
            },
            set: { draft.settings.mcp = $0 })

        Section("MCP Server") {
            Picker("Transport", selection: Binding(
                get: { mcpBinding.wrappedValue.server.transport },
                set: { mcpBinding.wrappedValue.server.transport = $0 })) {
                Text("HTTP").tag(MCPServerConfig.Transport.http)
                #if os(macOS)
                Text("stdio (local command)").tag(MCPServerConfig.Transport.stdio)
                #endif
            }
            switch mcpBinding.wrappedValue.server.transport {
            case .http:
                TextField("Server URL", text: Binding(
                    get: { mcpBinding.wrappedValue.server.url ?? "" },
                    set: { mcpBinding.wrappedValue.server.url = $0.isEmpty ? nil : $0 }))
                    .autocorrectionOff()
            case .stdio:
                TextField("Command (e.g. npx)", text: Binding(
                    get: { mcpBinding.wrappedValue.server.command ?? "" },
                    set: { mcpBinding.wrappedValue.server.command = $0.isEmpty ? nil : $0 }))
                TextField("Arguments (space-separated)", text: Binding(
                    get: { mcpBinding.wrappedValue.server.arguments.joined(separator: " ") },
                    set: { mcpBinding.wrappedValue.server.arguments = $0.split(separator: " ").map(String.init) }))
            }
        }
        Section("Tool Call") {
            TextField("Tool name", text: Binding(
                get: { mcpBinding.wrappedValue.tool },
                set: { mcpBinding.wrappedValue.tool = $0 }))
            TextField("Arguments JSON (optional)", text: Binding(
                get: { mcpBinding.wrappedValue.argumentsJSON ?? "" },
                set: { mcpBinding.wrappedValue.argumentsJSON = $0.isEmpty ? nil : $0 }))
                .font(.system(.body, design: .monospaced))
        }
    }

    /// Saved sign-in for pages behind a login. Credentials live in the
    /// Keychain for the page's host — never in the dashboard, so they are not
    /// synced, exported, or shared with a board.
    @ViewBuilder
    private var signInSection: some View {
        let host = WebClipCredentialStore.host(for: draft.settings.url)
        Section("Sign In") {
            if let host {
                Toggle("Sign in automatically", isOn: $draft.settings.webClipAutoLogin)
                if draft.settings.webClipAutoLogin {
                    if savedCredentialHost == host {
                        LabeledContent("Saved for") { Text(host) }
                        Button("Remove Saved Password", role: .destructive) {
                            WebClipCredentialStore.delete(host: host)
                            savedCredentialHost = nil
                            loginUsername = ""
                            loginPassword = ""
                        }
                    } else {
                        TextField("Username or email", text: $loginUsername)
                            .autocorrectionOff()
                        SecureField("Password", text: $loginPassword)
                        Button("Save Password to Keychain") {
                            let credential = WebClipCredential(host: host,
                                                               username: loginUsername,
                                                               password: loginPassword)
                            if WebClipCredentialStore.save(credential) {
                                savedCredentialHost = host
                                loginPassword = ""
                            }
                        }
                        .disabled(loginUsername.isEmpty || loginPassword.isEmpty)
                    }
                    Text("Stored in the Keychain for \(host). Single sign-on is handled: a clip redirected to another sign-in host on \(WebClipCredentialStore.domain(for: host)) uses this same saved password, and portals that ask for the username first then the password are filled one step at a time. Auto-login stops after four failed tries.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Set a page URL first to save a sign-in for it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let host, WebClipCredentialStore.hasCredential(host: host) {
                savedCredentialHost = host
            }
        }
    }

    /// Connector binding shared by the school panels.
    private var canvasConnector: Binding<ConnectorConfig> {
        Binding(get: { draft.settings.connector ?? ConnectorConfig() },
                set: { draft.settings.connector = $0 })
    }

    /// Rename classes to something short and human. Course names are taken
    /// from the panel's current data, so there's nothing to type from memory.
    @ViewBuilder
    private var aliasSection: some View {
        let names = courseNamesInCurrentData()
        if !names.isEmpty {
            Section("Class Names") {
                ForEach(names, id: \.self) { name in
                    LabeledContent {
                        TextField(name, text: Binding(
                            get: { draft.settings.courseAliases[name] ?? "" },
                            set: { newValue in
                                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                                    draft.settings.courseAliases.removeValue(forKey: name)
                                } else {
                                    draft.settings.courseAliases[name] = newValue
                                }
                            }))
                        .multilineTextAlignment(.trailing)
                    } label: {
                        Text(name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !draft.settings.courseAliases.isEmpty {
                    Button("Clear All Aliases", role: .destructive) {
                        draft.settings.courseAliases.removeAll()
                    }
                }
                Text("Leave blank to keep the school's name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The class names present in whatever this panel last loaded.
    private func courseNamesInCurrentData() -> [String] {
        guard let snapshot = model.snapshots.record(for: draft.snapshotKey)?.snapshot else {
            return []
        }
        switch snapshot {
        case .grades(let grades):
            return grades.map(\.course)
        case .schedule(let classes):
            return Array(Set(classes.map(\.course))).sorted()
        case .assignments(let digest):
            let all = digest.due + digest.late + digest.redo
            return Array(Set(all.map(\.course).filter { !$0.isEmpty })).sorted()
        default:
            return []
        }
    }

    // MARK: - Shared sections

    private var appearanceSection: some View {
        Section("Appearance") {
            ColorPicker("Accent color", selection: Binding(
                get: { draft.settings.accentColor ?? SBTheme.accent },
                set: { draft.settings.accentColorHex = $0.hexString() }))
            if draft.settings.accentColorHex != nil {
                Button("Use Theme Color") {
                    draft.settings.accentColorHex = nil
                }
            }
        }
    }

    /// Threshold alerts make sense wherever the panel's data is a number.
    private var supportsAlerts: Bool {
        switch draft.kind {
        case .graph, .progress, .bridge, .mcp, .supabase, .logs, .status, .health:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var alertSection: some View {
        if supportsAlerts {
            Section("Alerts") {
                TextField("Notify when above…", text: optionalDouble($draft.settings.alertAbove))
                TextField("Notify when below…", text: optionalDouble($draft.settings.alertBelow))
                Text("Sends a notification when the value crosses a limit, and again when it recovers. 15-minute cooldown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var liveActivitySection: some View {
        #if os(iOS)
        if supportsAlerts {
            Section("Live Activity") {
                if LiveActivityManager.shared.isActive(key: draft.snapshotKey) {
                    Button("Stop Live Activity", role: .destructive) {
                        LiveActivityManager.shared.stop(key: draft.snapshotKey)
                    }
                } else {
                    Button {
                        var value: Double?
                        var unit: String? = draft.settings.unit
                        switch model.snapshots.record(for: draft.snapshotKey)?.snapshot {
                        case .number(let number, let numberUnit):
                            value = number
                            unit = numberUnit ?? unit
                        case .series(let series):
                            value = series.points.last?.value
                            unit = series.unit ?? unit
                        default:
                            break
                        }
                        try? LiveActivityManager.shared.start(panel: draft, value: value, unit: unit)
                    } label: {
                        Label("Show in Dynamic Island", systemImage: "bolt.badge.clock")
                    }
                    Text("Pins this panel's value to the Dynamic Island and Lock Screen, updating live.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }

    // MARK: - Binding helpers

    private func optionalString(_ source: Binding<String?>) -> Binding<String> {
        Binding(get: { source.wrappedValue ?? "" },
                set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalDouble(_ source: Binding<Double?>) -> Binding<String> {
        Binding(get: { source.wrappedValue.map { String($0) } ?? "" },
                set: { source.wrappedValue = Double($0) })
    }
}

extension View {
    func autocorrectionOff() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
#endif
