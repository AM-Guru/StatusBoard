#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// The settings for a HomeKit, Home Assistant or Nest panel.
///
/// One view for all three because they ask almost the same questions — which
/// mode, which device, which rooms — and differ only in how they connect.
/// Keeping them together is what stops the three integrations drifting into
/// three subtly different editors.
struct HomeSettingsSection: View {
    let provider: HomeProvider
    @Binding var draft: Panel
    /// Room names read from whatever the panel last loaded, so nothing has to
    /// be typed from memory. Empty before the first fetch.
    let knownRooms: [String]

    @State private var choices: [HomeDeviceChoice] = []
    @State private var isLoadingChoices = false
    @State private var lookupError: String?
    @State private var showingNestSignIn = false
    @State private var homeNames: [String] = []

    var body: some View {
        modeSection
        connectionSection
        if draft.settings.homeMode.isThermostat || draft.settings.homeMode == .camera {
            targetSection
        }
        if !draft.settings.homeMode.isThermostat && draft.settings.homeMode != .camera {
            sensorSection
            roomSection
        }
        if draft.settings.homeMode.isThermostat {
            thermostatSection
        }
        if draft.settings.homeMode != .camera {
            unitsSection
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        Section("Show") {
            Picker("Mode", selection: $draft.settings.homeMode) {
                ForEach(provider.supportedModes) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .onChange(of: draft.settings.homeMode) { _, _ in
                // The device lists for a thermostat and a camera have nothing
                // in common, so a stale one would offer the wrong choices.
                choices = []
                loadChoices()
            }
            Text(draft.settings.homeMode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if provider == .nest {
                Text("Google's API exposes Nest thermostats only — its separate Temperature Sensors and its cameras aren't available through it. Home Assistant's Nest integration does expose the cameras, if you run one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        switch provider {
        case .homeKit:
            Section("HomeKit") {
                if HomeKitSource.isAvailable {
                    if homeNames.count > 1 {
                        Picker("Home", selection: optionalString($draft.settings.homeName)) {
                            Text("Primary home").tag("")
                            ForEach(homeNames, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Text("Reads the accessories already paired to this Apple ID. Nothing to set up, and nothing leaves your devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("HomeKit isn't available on this platform.", systemImage: "info.circle")
                        .font(.footnote)
                    Text("Set the panel up on an iPhone, iPad or Apple TV — it will appear here through iCloud sync, showing the values that device fetched.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .task { homeNames = await HomeKitSource.homeNames() }

        case .homeAssistant:
            Section("Home Assistant") {
                TextField("Address, e.g. homeassistant.local:8123",
                          text: optionalString(connector.projectURL))
                    .autocorrectionOff()
                SecureField("Long-lived access token", text: optionalString(connector.token))
                Text("Create the token in Home Assistant under your profile ▸ Security ▸ Long-lived access tokens. It's shared with your other Home Assistant panels, and stored in the Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .nest:
            Section("Google Nest") {
                LabeledContent("Account") {
                    if NestCredentials.shared.isConfigured {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(SBTheme.good)
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }
                Button(NestCredentials.shared.isConfigured
                       ? "Connect Again…" : "Connect Google Account…") {
                    showingNestSignIn = true
                }
                if NestCredentials.shared.isConfigured {
                    Button("Disconnect", role: .destructive) {
                        NestCredentials.shared.clear()
                        choices = []
                    }
                }
                Text("Nest needs a Google Device Access project (a one-time $5 registration with Google) and an OAuth client. Status Board then talks to Google directly — the sign-in stays in this device's Keychain and never syncs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showingNestSignIn) {
                NestSignInView { loadChoices() }
            }
        }
    }

    // MARK: - Device

    private var targetSection: some View {
        Section(draft.settings.homeMode == .camera ? "Camera" : "Thermostat") {
            HStack {
                Picker(draft.settings.homeMode == .camera ? "Camera" : "Thermostat",
                       selection: optionalString($draft.settings.homeTarget)) {
                    Text(choices.isEmpty ? "First one found" : "First one found").tag("")
                    ForEach(choices) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .disabled(choices.isEmpty)
                Button {
                    loadChoices()
                } label: {
                    if isLoadingChoices {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingChoices)
            }
            if let selected = choices.first(where: { $0.id == draft.settings.homeTarget }),
               let subtitle = selected.subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let lookupError {
                Label(lookupError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(SBTheme.warn)
            }
            if choices.isEmpty && !isLoadingChoices && lookupError == nil {
                Text("Tap refresh once the connection above is filled in, and the panel will list what it can see.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { loadChoices() }
    }

    // MARK: - Sensors and rooms

    private var sensorSection: some View {
        Section("Readings") {
            ForEach(HomeSensorKind.allCases.filter { $0 != .other }) { kind in
                Toggle(isOn: showsKind(kind)) {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }
            Text("Leave everything off to use the sensible set for this mode.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var roomSection: some View {
        Section("Rooms") {
            if knownRooms.isEmpty {
                Text("Every room is shown. Once the panel has loaded once, its rooms are listed here to pick from.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(knownRooms, id: \.self) { room in
                    Toggle(room, isOn: showsRoom(room))
                }
                if !draft.settings.homeRooms.isEmpty {
                    Button("Show All Rooms") { draft.settings.homeRooms = [] }
                }
            }
        }
    }

    // MARK: - Thermostat extras

    private var thermostatSection: some View {
        Section("Trend & Health") {
            Picker("History", selection: $draft.settings.hvacTrendHours) {
                Text("3 hours").tag(3.0)
                Text("6 hours").tag(6.0)
                Text("12 hours").tag(12.0)
                Text("24 hours").tag(24.0)
                Text("3 days").tag(72.0)
                Text("7 days").tag(168.0)
            }
            if draft.settings.homeMode == .thermostat {
                Toggle("Show equipment health", isOn: $draft.settings.showsHVACDiagnostics)
                Toggle("Show other room temperatures", isOn: $draft.settings.showsHomeRoomStrip)
            }
            Text("Status Board records a reading every refresh and works out the cycling, runtime and anything that looks wrong — none of the three services provides that. Short runs are only visible if the panel refreshes at least as often as they last, so a one-minute refresh is worth it here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Temperature", selection: $draft.settings.weatherUnits) {
                ForEach(WeatherUnits.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    // MARK: - Plumbing

    private var connector: Binding<ConnectorConfig> {
        Binding(get: { draft.settings.connector ?? ConnectorConfig() },
                set: { draft.settings.connector = $0 })
    }

    private func showsKind(_ kind: HomeSensorKind) -> Binding<Bool> {
        Binding(get: { draft.settings.homeSensorKinds.contains(kind) },
                set: { isOn in
                    var kinds = draft.settings.homeSensorKinds
                    if isOn {
                        if !kinds.contains(kind) { kinds.append(kind) }
                    } else {
                        kinds.removeAll { $0 == kind }
                    }
                    draft.settings.homeSensorKinds = kinds
                })
    }

    /// Checked means shown, so the box reads the way the panel looks — and an
    /// empty list means everything, not nothing.
    private func showsRoom(_ room: String) -> Binding<Bool> {
        Binding(get: {
            draft.settings.homeRooms.isEmpty || draft.settings.homeRooms.contains(room)
        }, set: { isOn in
            var rooms = draft.settings.homeRooms
            if rooms.isEmpty { rooms = knownRooms }
            if isOn {
                if !rooms.contains(room) { rooms.append(room) }
            } else {
                rooms.removeAll { $0 == room }
            }
            draft.settings.homeRooms = Set(rooms) == Set(knownRooms) ? [] : rooms
        })
    }

    private func optionalString(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" },
                set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func loadChoices() {
        guard draft.settings.homeMode.isThermostat || draft.settings.homeMode == .camera else {
            return
        }
        isLoadingChoices = true
        lookupError = nil
        let mode = draft.settings.homeMode
        let config = draft.settings.connector ?? ConnectorConfig()
        let homeName = draft.settings.homeName
        Task {
            defer { isLoadingChoices = false }
            do {
                switch provider {
                case .homeKit:
                    choices = await HomeKitSource.choices(mode: mode, homeName: homeName)
                    if choices.isEmpty {
                        lookupError = HomeKitSource.isAvailable
                            ? "Nothing found in this home yet."
                            : "HomeKit isn't available on this platform."
                    }
                case .homeAssistant:
                    let resolved = await HomeAssistantCredentials.resolved(config)
                    choices = try await HomeAssistantSource.choices(mode: mode, config: resolved)
                    if choices.isEmpty {
                        lookupError = "Nothing of that kind on this Home Assistant."
                    }
                case .nest:
                    choices = try await NestSource.choices()
                    if choices.isEmpty { lookupError = "No thermostats on this account." }
                }
            } catch {
                choices = []
                lookupError = error.localizedDescription
            }
        }
    }
}

/// The Google Device Access sign-in.
///
/// Google will not let an app intercept this redirect: Device Access requires
/// an OAuth client of type "Web application", whose redirect must be an https
/// URL, and Google blocks embedded web views for sign-in outright. So the
/// honest flow is the one Google's own documentation describes — open the
/// consent page in the real browser, and bring the code back by hand. It is
/// one paste, once.
struct NestSignInView: View {
    var onSignedIn: () -> Void

    @State private var setup = NestCredentials.Setup()
    @State private var pasted = ""
    @State private var error: String?
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Device Access") {
                    TextField("Project ID", text: $setup.projectID)
                        .autocorrectionOff()
                    TextField("OAuth client ID", text: $setup.clientID)
                        .autocorrectionOff()
                    SecureField("OAuth client secret", text: $setup.clientSecret)
                    Text("From the Device Access Console and your Google Cloud project. The client must be of type “Web application”, with \(NestCredentials.defaultRedirectURI) as an authorized redirect URI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("1. Authorize") {
                    Button("Open Google Consent Page") {
                        guard let url = NestCredentials.authorizationURL(setup) else {
                            error = "Fill in the project ID and client ID first."
                            return
                        }
                        openURL(url)
                    }
                    .disabled(setup.projectID.isEmpty || setup.clientID.isEmpty)
                    Text("Pick the thermostats to share, then sign in to Google. The browser will land on a page that can't load — that's expected. Copy its address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("2. Paste it back") {
                    TextField("Pasted address, or just the code", text: $pasted, axis: .vertical)
                        .autocorrectionOff()
                        .lineLimit(1...4)
                        .font(.system(.caption, design: .monospaced))
                    Button(isWorking ? "Connecting…" : "Connect") { connect() }
                        .disabled(isWorking || pasted.isEmpty
                                  || setup.clientSecret.isEmpty || setup.clientID.isEmpty)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(SBTheme.warn)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect Nest")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
        .onAppear { setup = NestCredentials.shared.setup }
    }

    private func connect() {
        guard let code = NestCredentials.authorizationCode(fromPasted: pasted) else {
            error = "That doesn't look like an authorization code. Paste the whole address from the browser."
            return
        }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await NestCredentials.shared.signIn(setup: setup, code: code)
                onSignedIn()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
