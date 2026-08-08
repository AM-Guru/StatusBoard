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
    @State private var tessieVehicles: [TessieSource.VehicleSummary] = []
    @State private var tessieLookupError: String?
    @State private var isLoadingTessieVehicles = false
    @State private var calendarChoices: [CalendarChoice] = []
    @State private var calendarLookupError: String?
    @Environment(\.dismiss) private var dismiss

    @MainActor
    public init(model: AppModel, panel: Panel, dashboardID: Dashboard.ID) {
        self.model = model
        self.dashboardID = dashboardID
        // A Canvas panel arrives already filled in from whatever a previous
        // one was signed in with. Done here rather than in `onAppear` so it
        // counts as the panel's starting state, not as an unsaved edit that
        // would then block swiping the sheet away.
        var panel = panel
        if panel.kind.usesCanvasCredentials {
            var connector = panel.settings.connector ?? ConnectorConfig()
            CanvasCredentials.shared.applyDefaults(to: &connector)
            panel.settings.connector = connector
        }
        if panel.kind.usesTessieCredentials {
            var connector = panel.settings.connector ?? ConnectorConfig()
            TessieCredentials.shared.applyDefaults(to: &connector)
            panel.settings.connector = connector
        }
        if panel.kind == .homeAssistant {
            var connector = panel.settings.connector ?? ConnectorConfig()
            HomeAssistantCredentials.shared.applyDefaults(to: &connector)
            panel.settings.connector = connector
        }
        // A panel saved before multi-feed support keeps its one URL in
        // `settings.url`; lift it into the editable list so it shows up as a
        // row rather than looking like the panel lost its feed.
        if panel.kind == .feed {
            panel.settings.migrateFeedSourcesIfNeeded()
        }
        self.original = panel
        self._draft = State(initialValue: panel)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Panel") {
                    TextField("Title", text: $draft.title)
                    if draft.isSharedAcrossDashboards {
                        Label("Shared across \(model.store.linkedPlacementCount(for: draft)) dashboards. Content and appearance changes update every placement; layout stays independent.",
                              systemImage: "link")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                portableSnapshotSection
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
                        normalizeFeedSettings()
                        normalizeCalendarSettings()
                        model.store.updatePanel(draft, in: dashboardID)
                        shareCanvasCredentials()
                        shareTessieCredentials()
                        shareHomeAssistantCredentials()
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
        .task(id: draft.kind) {
            guard draft.kind == .calendar else { return }
            do {
                calendarChoices = try await CalendarSource.availableCalendars()
                calendarLookupError = nil
            } catch {
                calendarLookupError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var kindSections: some View {
        switch draft.kind {
        case .clock:
            clockSections

        case .weather:
            WeatherLocationSection(settings: $draft.settings)
            Section("Forecast") {
                Picker("Day layout", selection: $draft.settings.weatherForecastLayout) {
                    ForEach(WeatherForecastLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                Text("Automatic places days across wide panels and down tall or narrow panels. The choice also applies to WidgetKit sizes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            feedSourcesSection
            Section("Display") {
                Picker("Display", selection: $draft.settings.listDisplay) {
                    ForEach(ListDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Show site icons", isOn: $draft.settings.feedShowsSourceIcons)
                Toggle("Show source names", isOn: $draft.settings.feedShowsSourceNames)
                Text("Items from every feed are merged into one list, newest first. Source names appear once a panel has more than one feed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .calendar:
            calendarSection

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
                     ? "Shows every active course, scored on work a teacher has actually marked. An hourglass counts what's still waiting on a grade; a course with nothing graded yet shows a dash rather than a failing score."
                     : "Due today and late work. Anything finished at 100%, or handed in and waiting on a grade, is hidden. Graded below 100% moves to Re-Do.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                canvasSharingNote
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
                k12SignInStatus
                Button(K12Session.shared.isSignedIn ? "Sign In Again…" : "Sign In to K12…") {
                    showingK12SignIn = true
                }
                Text("Shows the classes still to come today, with a live countdown. Tap one to open it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            aliasSection

        case .tessie:
            tessieSections

        case .homeKit, .homeAssistant, .nest:
            if let provider = draft.kind.homeProvider {
                HomeSettingsSection(provider: provider, draft: $draft,
                                    knownRooms: roomNamesInCurrentData())
            }

        case .health:
            Section("Health") {
                Picker("Metric", selection: $draft.settings.healthMetric) {
                    ForEach(HealthMetric.allCases, id: \.self) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }
                Text("Reads from Health on this device. Cross-device value sync is off by default and can be enabled below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Calendar

    private var calendarSection: some View {
        Section("Calendar") {
            Stepper("Next \(draft.settings.calendarDaysAhead) days",
                    value: $draft.settings.calendarDaysAhead, in: 1...60)
            Picker("Display", selection: $draft.settings.listDisplay) {
                ForEach(ListDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if calendarChoices.isEmpty, calendarLookupError == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading calendars…").foregroundStyle(.secondary)
                }
            }
            ForEach(calendarChoices) { choice in
                Toggle(isOn: calendarBinding(choice)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.title)
                        Text(choice.source).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !draft.settings.calendarIdentifiers.isEmpty
                || !draft.settings.calendarNames.isEmpty {
                Button("Show All Calendars") {
                    draft.settings.calendarIdentifiers.removeAll()
                    draft.settings.calendarNames.removeAll()
                }
            }
            if let calendarLookupError {
                Label(calendarLookupError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(SBTheme.bad)
            }
            Text("Empty selections mean all calendars. Names are saved beside system identifiers so the selection can follow the board to another Apple device. Apple TV displays the latest private iCloud snapshot or the live snapshot relayed by the Mac bridge.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func calendarBinding(_ choice: CalendarChoice) -> Binding<Bool> {
        Binding {
            let settings = draft.settings
            return (settings.calendarIdentifiers.isEmpty && settings.calendarNames.isEmpty)
                || settings.calendarIdentifiers.contains(choice.id)
                || settings.calendarNames.contains(choice.matchName)
        } set: { selected in
            // The first deselection turns implicit "all" into an explicit set,
            // then removes just the calendar the user switched off.
            if draft.settings.calendarIdentifiers.isEmpty && draft.settings.calendarNames.isEmpty {
                draft.settings.calendarIdentifiers = Set(calendarChoices.map(\.id))
                draft.settings.calendarNames = Set(calendarChoices.map(\.matchName))
            }
            if selected {
                draft.settings.calendarIdentifiers.insert(choice.id)
                draft.settings.calendarNames.insert(choice.matchName)
            } else {
                draft.settings.calendarIdentifiers.remove(choice.id)
                draft.settings.calendarNames.remove(choice.matchName)
            }
        }
    }

    // MARK: - Clock

    /// The face, then the options that face actually uses. Sun faces need a
    /// place, so they borrow the weather panel's location picker.
    @ViewBuilder
    private var clockSections: some View {
        let style = draft.settings.clockStyle
        Section("Face") {
            Picker("Face", selection: Binding(
                get: { draft.settings.clockStyle },
                set: { newStyle in
                    draft.settings.clockStyle = newStyle
                    resizeForClockFace(newStyle)
                })) {
                ForEach(ClockStyle.allCases) { face in
                    Label(face.displayName, systemImage: face.symbolName).tag(face)
                }
            }
            Text(clockFaceExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Section("Clock") {
            Picker("Hours", selection: $draft.settings.clockHourFormat) {
                ForEach(ClockHourFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            TextField("Time zone ID (e.g. Europe/Paris)",
                      text: optionalString($draft.settings.timeZoneID))
            if style.supportsSeconds {
                Toggle("Show seconds", isOn: $draft.settings.showsSeconds)
            }
            if style == .solar {
                Toggle("Show clock hands", isOn: $draft.settings.showsClockHands)
                if draft.settings.showsClockHands {
                    Text(draft.settings.showsSeconds
                         ? "Hour, minute, and second hands are shown."
                         : "Hour and minute hands are shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if style != .sunTimes && style != .sunArc {
                Toggle("Show date", isOn: $draft.settings.showsClockDate)
            }
            if style.usesLocation && !style.needsLocation {
                Toggle("Show the sun's position", isOn: $draft.settings.showsSunPosition)
            }
        }
        if style.usesLocation {
            WeatherLocationSection(settings: $draft.settings,
                                   modes: [.coordinates, .place, .current],
                                   showsUnits: false)
            Section {
                Text("Sunrise and sunset are worked out on this device from the date and these coordinates — nothing is looked up over the network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clockFaceExplanation: String {
        switch draft.settings.clockStyle {
        case .lcd: return "Big LCD digits over a date line — the classic Status Board clock."
        case .flip: return "A split-flap board: each digit on its own card, flipping as it changes."
        case .analog: return "Hands on a tick dial, sized to the panel. Squarer panels suit it best."
        case .dial: return "The whole day on one ring, midnight at the bottom and noon at the top, with daylight drawn as an arc when a location is set."
        case .modular: return "Oversized time with the weekday, date and seconds arranged around it — widest at three or more cells across."
        case .solar: return "A 24-hour dial with midnight at the bottom and noon at the top, its sky split along the line from sunrise to sunset — so the horizon turns through the year as the days lengthen — and the sun riding the ring at the hour it is now."
        case .sunBand: return "The same day unrolled: midnight to midnight left to right, the golden hour and each stage of twilight in its own band, and the sun on its altitude curve."
        case .sunArc: return "The sun's path across the panel: sunrise at one end, sunset at the other, and the sun where it is now."
        case .sunTimes: return "Sunrise and sunset as times, with a bar showing how much daylight is left."
        }
    }

    /// Faces have very different natural shapes, so choosing one grows a panel
    /// that is too small for it. Nothing is ever shrunk, nothing grows past the
    /// board, and a panel with a neighbour in the way is left exactly as it is
    /// — a face change must never shuffle the board underneath the user.
    private func resizeForClockFace(_ style: ClockStyle) {
        guard let board = model.store.dashboard(id: dashboardID) else { return }
        let suggested = style.suggestedSize
        var frame = draft.frame
        frame.width = min(max(frame.width, suggested.width), board.grid.columns)
        frame.height = min(max(frame.height, suggested.height), board.grid.rows)
        frame = frame.clamped(to: board.grid)
        let others = board.panels.filter { $0.id != draft.id }
        guard !others.contains(where: { $0.frame.intersects(frame) }) else { return }
        draft.frame = frame
    }

    // MARK: - Feeds

    /// One row per feed, merged into a single list at fetch time.
    @ViewBuilder
    private var feedSourcesSection: some View {
        Section("Feeds") {
            ForEach($draft.settings.feedSources) { $source in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name (optional)", text: $source.name)
                            .font(.headline)
                        Toggle("Include", isOn: $source.isEnabled)
                            .labelsHidden()
                            .accessibilityLabel("Include \(feedRowLabel(source))")
                    }
                    TextField("RSS / Atom URL", text: $source.url)
                        .autocorrectionOff()
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(source.isEnabled ? .primary : .secondary)
                }
                .padding(.vertical, 2)
            }
            .onDelete { draft.settings.feedSources.remove(atOffsets: $0) }
            .onMove { draft.settings.feedSources.move(fromOffsets: $0, toOffset: $1) }

            Button {
                draft.settings.feedSources.append(FeedSource())
            } label: {
                Label("Add Feed", systemImage: "plus.circle")
            }

            if draft.settings.feedSources.isEmpty {
                Text("Add one or more RSS or Atom feeds. Leave a name blank to use the feed's own title.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tidies the feed list on the way out: blank rows added and never filled
    /// in are dropped, and the legacy single-URL field is kept pointing at the
    /// first feed so older builds (and synced devices) still fetch something.
    private func normalizeFeedSettings() {
        guard draft.kind == .feed else { return }
        var sources = draft.settings.feedSources
        for index in sources.indices {
            sources[index].url = sources[index].trimmedURL
            sources[index].name = sources[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        sources.removeAll { $0.url.isEmpty }
        draft.settings.feedSources = sources
        draft.settings.url = sources.first(where: \.isEnabled)?.url ?? sources.first?.url
    }

    private func normalizeCalendarSettings() {
        guard draft.kind == .calendar, !calendarChoices.isEmpty else { return }
        let everyID = Set(calendarChoices.map(\.id))
        if draft.settings.calendarIdentifiers.isSuperset(of: everyID) {
            draft.settings.calendarIdentifiers.removeAll()
            draft.settings.calendarNames.removeAll()
        }
    }

    private func feedRowLabel(_ source: FeedSource) -> String {
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let trimmed = source.trimmedURL
        return trimmed.isEmpty ? "this feed" : trimmed
    }

    // MARK: - Tessie

    private var tessieConnector: Binding<ConnectorConfig> {
        Binding(get: { draft.settings.connector ?? ConnectorConfig() },
                set: { draft.settings.connector = $0 })
    }

    @ViewBuilder
    private var tessieSections: some View {
        Section("Tessie") {
            SecureField("API key", text: optionalString(tessieConnector.token))
            HStack {
                TextField("VIN", text: optionalString(tessieConnector.query))
                    .autocorrectionOff()
                Button {
                    loadTessieVehicles()
                } label: {
                    if isLoadingTessieVehicles {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled((tessieConnector.wrappedValue.token ?? "").isEmpty
                          || isLoadingTessieVehicles)
            }
            // Typing a VIN from memory is a mistake waiting to happen, so the
            // account's own cars are offered as soon as the key works.
            if !tessieVehicles.isEmpty {
                Picker("Vehicle", selection: Binding(
                    get: { tessieConnector.wrappedValue.query ?? "" },
                    set: { tessieConnector.wrappedValue.query = $0.isEmpty ? nil : $0 })) {
                    Text("First on the account").tag("")
                    ForEach(tessieVehicles) { vehicle in
                        Text(vehicle.name).tag(vehicle.vin)
                    }
                }
            }
            if let tessieLookupError {
                Label(tessieLookupError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(SBTheme.warn)
            }
            Text("Create a key at tessie.com under Settings → API. Leave the VIN blank to show the first car on the account. This panel only reads — it never sends commands to the car.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Label("The API key is shared with every Tesla panel — saving here updates them all.",
                  systemImage: "link")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Layout") {
            Toggle("Switch layouts automatically", isOn: $draft.settings.tessieAutoContext)
            if !draft.settings.tessieAutoContext {
                Picker("Always show", selection: $draft.settings.tessieContext) {
                    ForEach(TessieContext.allCases) { context in
                        Text(context.displayName).tag(context)
                    }
                }
                .pickerStyle(.segmented)
            }
            Text(draft.settings.tessieAutoContext
                 ? "The panel shows the Parked list while the car is in park, and swaps to the Driving list the moment it moves."
                 : "The panel always shows one list, which is what you want while arranging a board.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        tessieFieldSection("When Parked", fields: $draft.settings.tessieParkedFields)
        tessieFieldSection("When Driving", fields: $draft.settings.tessieDrivingFields)

        if draft.settings.tessieParkedFields.contains(.speed)
            || draft.settings.tessieDrivingFields.contains(.speed) {
            Section("Speed Limit") {
                Text("Neither Tesla nor Tessie publishes the posted speed limit, so the panel reads it from OpenStreetMap: while the car is moving, its coordinates go to overpass-api.de and the limit for the nearest road comes back. Nothing else is sent — no key, no VIN, no vehicle name — and nothing is asked while the car is parked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Tesla's own Speed Limit Mode is a cap the owner sets on the touchscreen, not the posted limit. It shows here too, when it is switched on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One context's field list. Selected fields sort to the top in the order
    /// they will be drawn, with the first one flagged as the headline — the
    /// arrangement decision that actually changes how the panel reads.
    @ViewBuilder
    private func tessieFieldSection(_ title: String,
                                    fields: Binding<[TessieField]>) -> some View {
        let selected = fields.wrappedValue
        let remaining = TessieField.allCases.filter { !selected.contains($0) }
        Section(title) {
            ForEach(selected + remaining) { field in
                let isOn = selected.contains(field)
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        if newValue {
                            if !fields.wrappedValue.contains(field) {
                                fields.wrappedValue.append(field)
                            }
                        } else {
                            fields.wrappedValue.removeAll { $0 == field }
                        }
                    })) {
                    HStack(spacing: 8) {
                        Image(systemName: field.symbolName)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(field.displayName)
                        if isOn, field != .map, selected.first == field {
                            Text("HEADLINE")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(SBTheme.accent)
                        }
                        Spacer(minLength: 0)
                        if isOn, field != .map, selected.first != field {
                            Button("Show First") {
                                fields.wrappedValue.removeAll { $0 == field }
                                fields.wrappedValue.insert(field, at: 0)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
            Text("The first field with data is drawn large; the rest become tiles. Map gets its own block wherever it sits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func loadTessieVehicles() {
        guard let key = tessieConnector.wrappedValue.token, !key.isEmpty else { return }
        isLoadingTessieVehicles = true
        tessieLookupError = nil
        Task {
            do {
                tessieVehicles = try await TessieSource.vehicles(apiKey: key)
                if tessieVehicles.isEmpty {
                    tessieLookupError = "No vehicles on this Tessie account"
                }
            } catch {
                tessieVehicles = []
                tessieLookupError = error.localizedDescription
            }
            isLoadingTessieVehicles = false
        }
    }

    /// Publishes the key typed here to every other Tesla panel, so rotating it
    /// doesn't leave the rest of the board signed out.
    private func shareTessieCredentials() {
        guard draft.kind.usesTessieCredentials, let connector = draft.settings.connector,
              TessieCredentials.shared.adopt(apiKey: connector.token,
                                             vin: connector.query) else { return }
        model.store.applyTessieCredentials(apiKey: TessieCredentials.shared.apiKey,
                                           excluding: draft.id)
    }

    private func shareHomeAssistantCredentials() {
        guard draft.kind == .homeAssistant, let connector = draft.settings.connector,
              HomeAssistantCredentials.shared.adopt(baseURL: connector.projectURL,
                                                    token: connector.token) else { return }
        model.store.applyHomeAssistantCredentials(
            baseURL: HomeAssistantCredentials.shared.baseURL,
            token: HomeAssistantCredentials.shared.token,
            excluding: draft.id)
    }

    /// The room names present in whatever this panel last loaded — so the
    /// room filter offers the house's own words rather than asking anyone to
    /// spell "Primary Bathroom" from memory.
    private func roomNamesInCurrentData() -> [String] {
        guard let snapshot = model.snapshots.record(for: draft.snapshotKey)?.snapshot else {
            return []
        }
        switch snapshot {
        case .homeSensors(let report):
            return report.byRoom.map(\.room)
        case .thermostat(let readout):
            return Array(Set(readout.rooms.compactMap(\.room))).sorted()
        default:
            return []
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
                canvasSharingNote
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
                k12SignInStatus
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

    /// Says out loud that these fields are shared, so changing them here to
    /// reach a different school doesn't quietly re-point every other panel.
    @ViewBuilder
    private var canvasSharingNote: some View {
        Label("Shared with every Canvas panel — saving here updates them all.",
              systemImage: "link")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Where the K12 sign-in stands, shared by the Schedule and K12 panels.
    ///
    /// "Expired" used to be the end of the story — someone had to come back and
    /// sign in by hand. The panel now renews the session on its own, so what
    /// this reports is whether that is working, not just whether the last call
    /// happened to succeed.
    @ViewBuilder
    private var k12SignInStatus: some View {
        LabeledContent("Sign-in") {
            switch K12Session.shared.state {
            case .signedIn:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SBTheme.good)
            case .expired:
                if K12Session.shared.canRecover {
                    Label("Reconnecting", systemImage: "arrow.clockwise")
                        .foregroundStyle(SBTheme.warn)
                } else {
                    Label("Expired", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SBTheme.warn)
                }
            case .signedOut:
                Text("Not signed in").foregroundStyle(.secondary)
            }
        }
        if let last = K12Session.shared.lastRecovery {
            Text("Signed back in automatically \(last.formatted(.relative(presentation: .named))).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Publishes the credentials typed here to every other Canvas panel, so a
    /// rotated token doesn't leave the rest of the board signed out.
    private func shareCanvasCredentials() {
        guard draft.kind.usesCanvasCredentials, let connector = draft.settings.connector,
              CanvasCredentials.shared.adopt(host: connector.projectURL,
                                             token: connector.token) else { return }
        model.store.applyCanvasCredentials(host: CanvasCredentials.shared.host,
                                           token: CanvasCredentials.shared.token,
                                           excluding: draft.id)
    }

    /// Rename classes to something short and human, and — on a Grades panel —
    /// uncheck the ones that aren't really graded courses. Course names are
    /// taken from the panel's current data, so there's nothing to type from
    /// memory, and an unchecked class stays listed here so it can come back.
    @ViewBuilder
    private var aliasSection: some View {
        let names = courseNamesInCurrentData()
        let hideable = draft.kind == .grades
        if !names.isEmpty {
            Section(hideable ? "Classes" : "Class Names") {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 10) {
                        if hideable {
                            Toggle("Show", isOn: showsCourse(name))
                                .labelsHidden()
                                .accessibilityLabel("Show \(name)")
                        }
                        Text(name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
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
                        .accessibilityLabel("Name shown for \(name)")
                    }
                }
                if !draft.settings.courseAliases.isEmpty {
                    Button("Clear All Aliases", role: .destructive) {
                        draft.settings.courseAliases.removeAll()
                    }
                }
                if hideable && !draft.settings.hiddenCourses.isEmpty {
                    Button("Show All Classes") {
                        draft.settings.hiddenCourses.removeAll()
                    }
                }
                Text(hideable
                     ? "Uncheck a class to leave it off the panel — handy for enrollments like Counselor that carry no grade. Leave the name blank to keep the school's."
                     : "Leave blank to keep the school's name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Checked means shown, so the box reads the way the panel looks.
    private func showsCourse(_ name: String) -> Binding<Bool> {
        Binding(get: { !draft.settings.hiddenCourses.contains(name) },
                set: { isOn in
                    if isOn {
                        draft.settings.hiddenCourses.remove(name)
                    } else {
                        draft.settings.hiddenCourses.insert(name)
                    }
                })
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

    @ViewBuilder
    private var portableSnapshotSection: some View {
        if draft.kind == .homeKit && draft.settings.homeMode == .camera {
            Section("Across Devices") {
                Label("Camera frames stay on this device", systemImage: "lock.shield")
                Text("Camera images are never stored in iCloud. Other boards and devices can use their own live camera connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if draft.kind == .calendar || draft.kind == .homeKit || draft.kind == .health {
            Section("Across Devices") {
                Toggle("Sync Latest Value with Private iCloud", isOn: Binding(
                    get: { draft.sharesLatestSnapshotViaICloud },
                    set: { draft.settings.syncSnapshotToICloud = $0 }))
                Text(portableSnapshotExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var portableSnapshotExplanation: String {
        switch draft.kind {
        case .calendar:
            return "Syncs this panel's event titles and start times so it works on Apple TV, which cannot read Calendar directly. Stored only in your private CloudKit database."
        case .homeKit:
            return "Syncs the latest sensor or thermostat reading so Macs can display it. Camera frames and equipment history are never synced."
        case .health:
            return "Off by default. If enabled, only this panel's latest rendered Health value is stored in your private CloudKit database so devices without HealthKit can display it."
        default:
            return ""
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        PanelAppearanceSection(
            appearance: $draft.settings.appearance,
            accentColorHex: $draft.settings.accentColorHex,
            kind: draft.kind,
            boardHasBackdrop: model.store.dashboard(id: dashboardID)?
                .appearance.hasBackdrop ?? false)
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
