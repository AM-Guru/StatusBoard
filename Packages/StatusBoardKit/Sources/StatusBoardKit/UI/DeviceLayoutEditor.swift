#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// Shows a board as another screen will show it — Apple TV, iPad, iPhone, Mac,
/// Watch — and lets that screen's arrangement be edited in place.
///
/// This fills the window's detail area rather than a sheet. Arranging a 1920×1080
/// TV board through a modal the size of a settings panel meant dragging panels
/// around a postage stamp; here the screen gets everything the window has, and
/// the options that used to crowd it sit in a column that can be closed.
///
/// The board is laid out at the target screen's real point size and then scaled
/// down to fit, so panel text shrinks in proportion: what looks cramped here
/// will look cramped on the TV.
public struct DeviceLayoutEditorView: View {
    @Bindable var model: AppModel
    let dashboardID: Dashboard.ID
    /// The screen being arranged. Chosen from the toolbar's screen menu.
    let device: SBDeviceClass

    @AppStorage("sb.simulator.tvSafeGuide") private var showsOverscanGuide = true
    /// Whether the glasses stage is drawn as the lenses actually show it — one
    /// colour, light on black. Off shows the same arrangement in full colour,
    /// which is easier to pick panels apart in while dragging them around.
    @AppStorage("sb.simulator.glassesMonochrome") private var showsMonochrome = true
    /// Relative to "fit in the stage". This is an editing aid only; it never
    /// changes the board or the target device's layout.
    @State private var previewZoom: CGFloat = 1
    @GestureState private var pinchScale: CGFloat = 1

    public init(model: AppModel, dashboardID: Dashboard.ID, device: SBDeviceClass) {
        self.model = model
        self.dashboardID = dashboardID
        self.device = device
    }

    private var board: Dashboard? { model.store.dashboard(id: dashboardID) }

    /// The single colour an Even Realities waveguide emits.
    private static let lensGreen = Color(hex: 0x5CFF9E)

    private var isMonochromePreview: Bool { device.isMonochrome && showsMonochrome }

    public var body: some View {
        GeometryReader { proxy in
            // Side by side once there's room for a screen and a column of
            // options; stacked and scrolling on a phone. Either way, closing the
            // options gives the screen the whole window.
            if !model.showsLayoutInspector {
                stage.padding(16)
            } else if proxy.size.width >= 820 {
                HStack(spacing: 0) {
                    stage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                    Divider()
                    ScrollView {
                        options.padding(20)
                    }
                    .frame(width: 320)
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        stage
                            .frame(height: max(300, proxy.size.height * 0.45))
                        options
                    }
                    .padding(16)
                }
            }
        }
        .background(SBTheme.background.opacity(0.6))
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 12) {
            orientationPicker
            GeometryReader { proxy in
                let size = device.nominalPointSize
                let fit = min(proxy.size.width / size.width,
                              proxy.size.height / size.height)
                let zoom = min(3, max(0.5, previewZoom * pinchScale))
                let scale = fit * zoom
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        Color.clear
                        screen(size: size, scale: scale)
                    }
                    .frame(width: max(proxy.size.width, size.width * scale),
                           height: max(proxy.size.height, size.height * scale))
                }
                .scrollIndicators(.automatic)
                .gesture(
                    MagnifyGesture()
                        .updating($pinchScale) { value, state, _ in
                            state = value.magnification
                        }
                        .onEnded { value in
                            previewZoom = min(3, max(0.5,
                                previewZoom * value.magnification))
                        }
                )
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Portrait and landscape are separate arrangements of the same board, so
    /// the screens that turn get a switch between them right above the stage —
    /// arranging one and then rotating to arrange the other is the whole point
    /// of having both.
    @ViewBuilder
    private var orientationPicker: some View {
        if device.supportsRotation {
            Picker("Orientation", selection: Binding(
                get: { device.orientation },
                set: { model.layoutTarget = device.inOrientation($0) })) {
                ForEach(SBLayoutOrientation.allCases) { orientation in
                    Label(orientation.displayName, systemImage: orientation.symbolName)
                        .tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    private var caption: String {
        let note = "\(device.displayName) · \(device.previewNote)"
        // The glasses are the one screen that isn't guaranteed to be there, so
        // their caption leads with whether anything is actually receiving this.
        let link = device == .glasses ? " \(model.glassesLink.statusDescription)" : ""
        return model.isEditing
            ? "\(note) — drag panels to arrange this screen. Tap one for its corner grips, or nudge it with the arrow keys; hold Option to resize.\(link)"
            : "\(note) — turn on Edit to arrange this screen.\(link)"
    }

    private func screen(size: CGSize, scale: CGFloat) -> some View {
        // Not a preview: these are the board's real panels, so configuring and
        // refreshing them from here works exactly as it does on the live board.
        // Only the layout being written is different.
        BoardView(model: model, dashboardID: dashboardID, layoutTarget: device)
            .frame(width: size.width, height: size.height)
            // Everything on this board is about to be shrunk to fit the window.
            // That is right for panel content and wrong for the resize grips, so
            // they are told to draw themselves bigger by the same factor and come
            // out the size a pointer or a fingertip actually needs. Capped, or a
            // TV board in a narrow pane would grow grips the size of its panels.
            .environment(\.sbEditorControlScale, min(3, 1 / max(scale, 0.05)))
            // Everything the lenses show arrives as one colour. Drawing the
            // stage the same way is the only way to find out, before putting a
            // board on someone's face, that the amber accent and the teal accent
            // are the same shade of green out there. Applied as a filter rather
            // than a mask so panels stay draggable through it.
            .grayscale(isMonochromePreview ? 1 : 0)
            .contrast(isMonochromePreview ? 1.3 : 1)
            .colorMultiply(isMonochromePreview ? Self.lensGreen : .white)
            .overlay {
                if showsOverscanGuide, let guide = device.screenGuide, guide.inset != .zero {
                    Rectangle()
                        .strokeBorder(SBTheme.warn.opacity(0.55),
                                      style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                        .padding(.horizontal, guide.inset.width)
                        .padding(.vertical, guide.inset.height)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(scale, anchor: .center)
            .frame(width: size.width * scale, height: size.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SBTheme.panelBorder, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: 22) {
            if device == .glasses {
                lensSection
            }
            layoutSection
            zoomSection
            if let guide = device.screenGuide, guide.inset != .zero {
                screenGuideSection(guide)
            }
            gridSection
            panelSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Preview Zoom")
            HStack(spacing: 10) {
                Button {
                    previewZoom = max(0.5, previewZoom - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel("Zoom out")
                Slider(value: $previewZoom, in: 0.5...3, step: 0.1) {
                    Text("Preview zoom")
                }
                Button {
                    previewZoom = min(3, previewZoom + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel("Zoom in")
            }
            HStack {
                Text("\(Int((previewZoom * 100).rounded()))% of fit")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fit") { previewZoom = 1 }
                    .disabled(previewZoom == 1)
            }
            Text("Pinch or use the slider to inspect and edit a target screen more closely. Zoom affects only this preview; scroll to reach the rest of the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Everything specific to a screen that isn't this app's to draw: whether
    /// anything is linked, whether the preview is honest about colour, and which
    /// panels won't survive the trip.
    private var lensSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Glasses")
            HStack(spacing: 8) {
                Image(systemName: model.glassesLink.isLive
                      ? "checkmark.circle.fill" : "eyeglasses")
                    .foregroundStyle(model.glassesLink.isLive ? SBTheme.good : .secondary)
                Text(model.glassesLink.statusDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Preview in Lens Green", isOn: $showsMonochrome)
                .toggleStyle(.switch)
            Text("The lenses emit one colour. With this on, the stage is drawn the way they will show it — turn it off while dragging panels if you want to tell them apart by colour.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.glassesLink.isLive {
                Toggle("Always Offer This Screen", isOn: Binding(
                    get: { model.glassesLink.alwaysOffered },
                    set: { model.glassesLink.alwaysOffered = $0 }))
                    .toggleStyle(.switch)
            }

            if !unsupportedPanels.isEmpty {
                Divider()
                Text("Not shown on the glasses")
                    .font(.callout.weight(.medium))
                Text("A 576×288 monochrome strip can't say anything useful with these, so the arrangement leaves them out. They stay on every other screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unsupportedPanels) { panel in
                    Label("\(panel.title) · \(panel.kind.displayName)",
                          systemImage: panel.kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var unsupportedPanels: [Panel] {
        (board?.panels ?? []).filter { !device.supports($0.kind) }
    }

    private var isCustom: Bool { board?.hasCustomLayout(for: device) ?? false }

    /// True while this screen is still arranging itself — the state a phone, a
    /// watch and an upright iPad are in until someone moves a panel on them.
    private var isAutomatic: Bool { board?.usesAutomaticLayout(for: device) ?? false }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Layout")
            Text(layoutExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The same edit mode the toolbar toggles; repeated here because it
            // is what the rest of this column is for. Turning it on writes
            // nothing: every edit made while a screen is targeted goes to that
            // screen's own layout, which is created the moment it is needed, so
            // looking at a screen never leaves an override behind.
            Toggle("Edit Layout", isOn: $model.isEditing)
                .toggleStyle(.switch)

            HStack(spacing: 10) {
                Button("Auto-Arrange") {
                    model.store.autoArrange(in: dashboardID, on: device)
                }
                .buttonStyle(.bordered)
                Menu("Copy From…") {
                    ForEach(SBDeviceClass.allCases.filter { $0 != device }) { source in
                        Button(source.displayName) {
                            model.store.copyLayout(in: dashboardID, from: source, to: device)
                        }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
            }

            if isCustom {
                Button(device.usesAutomaticLayout
                       ? "Reset to Automatic Layout" : "Reset to Shared Layout",
                       role: .destructive) {
                    model.store.resetLayout(in: dashboardID, on: device)
                }
            }
        }
    }

    private var layoutExplanation: String {
        if isCustom {
            return "\(device.displayName) has its own arrangement. Changes here don't touch your other devices."
        }
        if isAutomatic {
            let columns = device.suggestedGrid.columns
            let shape = columns == 1
                ? "a single column"
                : "\(columns) columns"
            let inherited = device.layoutFallback.map {
                " It starts from the \($0.displayName) arrangement and reflows it."
            } ?? ""
            return "\(device.displayName) arranges itself: panels reflow into \(shape) in reading order, and the board scrolls when it runs longer than the screen.\(inherited) Moving a panel here keeps what you see and makes it \(device.displayName)'s own."
        }
        return "\(device.displayName) follows the board's shared layout, the same one every device without its own arrangement uses. Moving a panel here gives it an arrangement of its own."
    }

    private func screenGuideSection(_ guide: SBDeviceClass.ScreenGuide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(guide.sectionTitle)
            Toggle(guide.toggleTitle, isOn: $showsOverscanGuide)
                .toggleStyle(.switch)
            Text(guide.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gridSection: some View {
        let grid = board?.grid(for: device) ?? BoardGrid()
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Grid")
            Stepper("Columns: \(grid.columns)") { step(columns: 1) } onDecrement: { step(columns: -1) }
            Stepper("Vertical units: \(grid.rows)") { step(rows: 1) } onDecrement: { step(rows: -1) }
            Picker("Vertical sizing", selection: Binding(
                get: { grid.verticalSubdivisions },
                set: { model.store.setVerticalSubdivisions($0, in: dashboardID, on: device) })) {
                Text("Full rows").tag(1)
                Text("Half rows").tag(2)
                Text("Quarter rows").tag(4)
            }
            .pickerStyle(.segmented)
            Text(device.allowsScrolling
                 ? "Use half- or quarter-row sizing for smaller height adjustments. Existing panels keep their size. Add more vertical units than fit and the board scrolls instead of squeezing them."
                 : "Use half- or quarter-row sizing for smaller height adjustments. Existing panels keep their size, and everything remains fitted to this non-scrolling screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(columns: Int = 0, rows: Int = 0) {
        guard let board else { return }
        var grid = board.grid(for: device)
        grid.columns = max(1, grid.columns + columns)
        grid.rows = max(1, grid.rows + rows)
        model.store.setGrid(grid, in: dashboardID, on: device)
    }

    private var panelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let panels = board?.panels ?? []
            sectionTitle("Panels on \(device.displayName)")
            if panels.isEmpty {
                Text("This board has no panels yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(panels) { panel in
                panelRow(panel)
            }
        }
    }

    private func panelRow(_ panel: Panel) -> some View {
        let hidden = board?.isHidden(panel.id, on: device) ?? false
        let frame = board?.frame(for: panel, device: device) ?? panel.frame
        return HStack(spacing: 10) {
            Image(systemName: panel.kind.symbolName)
                .frame(width: 22)
                .foregroundStyle(hidden ? .secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(frame.width)×\(frame.height) at \(frame.x),\(frame.y)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Toggle("Show \(panel.title) on \(device.displayName)", isOn: Binding(
                get: { !hidden },
                set: { model.store.setPanelHidden(!$0, panelID: panel.id,
                                                  in: dashboardID, on: device) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
        .opacity(hidden ? 0.55 : 1)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SBTheme.titleFont(size: 12))
            .foregroundStyle(.secondary)
    }
}
#endif
