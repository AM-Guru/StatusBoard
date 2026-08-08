#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// How a whole board looks: its theme, what is painted behind the panels, and
/// how far apart they sit.
///
/// The backdrop set here is also what panels sample when they are set to show
/// the board image masked through them, so this sheet previews the result at a
/// small scale rather than making the user close it to find out.
public struct BoardAppearanceView: View {
    let model: AppModel
    let dashboardID: Dashboard.ID
    private let original: BoardAppearance

    @State private var draft: BoardAppearance
    @Environment(\.dismiss) private var dismiss

    @MainActor
    public init(model: AppModel, dashboardID: Dashboard.ID) {
        self.model = model
        self.dashboardID = dashboardID
        let appearance = model.store.dashboard(id: dashboardID)?.appearance ?? BoardAppearance()
        self.original = appearance
        self._draft = State(initialValue: appearance)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(height: 150)
                        .listRowInsets(EdgeInsets())
                }
                Section("Theme") {
                    Picker("Board theme", selection: $draft.theme) {
                        ForEach(SBThemeName.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    Toggle("Apply to panels", isOn: $draft.appliesThemeToPanels)
                    Text("Panels that have picked a theme of their own always keep it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Background") {
                    Picker("Wallpaper", selection: $draft.wallpaper) {
                        ForEach(SBWallpaper.allCases) { wallpaper in
                            Text(wallpaper.displayName).tag(wallpaper)
                        }
                    }
                    ColorPicker("Base color", selection: Binding(
                        get: { draft.backgroundColorHex.flatMap(Color.init(hexString:))
                                ?? Color(hex: draft.theme.palette.boardBackground.first ?? 0x0E1013) },
                        set: { draft.backgroundColorHex = $0.hexString() }))
                    if draft.backgroundColorHex != nil {
                        Button("Use Theme Color") { draft.backgroundColorHex = nil }
                    }
                    TextField("Image URL (optional)", text: Binding(
                        get: { draft.backgroundImageURL ?? "" },
                        set: { draft.backgroundImageURL = $0.isEmpty ? nil : $0 }))
                        .autocorrectionOff()
                    if let url = draft.backgroundImageURL, !url.isEmpty {
                        Picker("Fit", selection: $draft.imageFill) {
                            ForEach(BackgroundImageFill.allCases) { fill in
                                Text(fill.displayName).tag(fill)
                            }
                        }
                        Button("Reload Image") { SBBackdropImageStore.shared.forget(url) }
                    }
                }
                Section("Gradient") {
                    ForEach(Array(draft.gradientColorHexes.enumerated()), id: \.offset) { index, hex in
                        ColorPicker("Color \(index + 1)", selection: Binding(
                            get: { Color(hexString: hex) ?? .gray },
                            set: { newValue in
                                guard let updated = newValue.hexString(),
                                      draft.gradientColorHexes.indices.contains(index) else { return }
                                draft.gradientColorHexes[index] = updated
                            }))
                    }
                    .onDelete { draft.gradientColorHexes.remove(atOffsets: $0) }
                    Button("Add Color") {
                        draft.gradientColorHexes.append(
                            draft.gradientColorHexes.isEmpty ? "#0B1220" : "#38BDF8")
                    }
                    .disabled(draft.gradientColorHexes.count >= 5)
                    if draft.gradientColorHexes.count >= 2 {
                        LabeledContent("Angle") {
                            Slider(value: $draft.gradientAngle, in: 0...360)
                        }
                    }
                }
                Section("Finish") {
                    LabeledContent("Darken") {
                        Slider(value: $draft.scrim, in: 0...0.8)
                    }
                    LabeledContent("Blur") {
                        Slider(value: $draft.backgroundBlur, in: 0...40)
                    }
                    LabeledContent("Fade") {
                        Slider(value: $draft.backgroundOpacity, in: 0.1...1)
                    }
                    LabeledContent("Panel spacing") {
                        Slider(value: $draft.panelSpacing, in: 0...48, step: 1)
                    }
                    Text("\(Int(draft.panelSpacing)) pt between panels. Wider gaps let more of the background through — which is what makes a picture masked across several panels read as one image.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Content size") {
                        Slider(value: $draft.contentScale, in: 0.75...2, step: 0.05)
                    }
                    Text("\(Int((draft.contentScale * 100).rounded()))%. Larger content scrolls on iPhone, iPad, Mac, and Apple Watch rather than being clipped. Apple TV always fits its safe area.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Animate", isOn: $draft.animates)
                        .disabled(!draft.wallpaper.isAnimated)
                }
                Section {
                    Button("Reset to Default", role: .destructive) {
                        draft = BoardAppearance()
                    }
                    .disabled(draft.isDefault)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Board Appearance")
            .interactiveDismissDisabled(draft != original)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var board = model.store.dashboard(id: dashboardID) {
                            board.appearance = draft
                            model.store.update(board, undoActionName: "Change Board Appearance")
                        }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    /// A miniature of the board: the backdrop, with three cut-outs standing in
    /// for panels so the masking effect is visible while it is being set up.
    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                SBBoardBackdropView(appearance: draft, size: proxy.size)
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(hex: draft.theme.palette.background.first ?? 0x191D23)
                                .opacity(index == 1 ? 0 : 0.85))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(hex: draft.theme.palette.border), lineWidth: 1)
                            }
                    }
                }
                .padding(12)
            }
            .clipped()
        }
    }
}
#endif
