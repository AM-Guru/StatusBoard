#if !os(tvOS) && !os(watchOS)
import SwiftUI

/// Shows a board as another screen will show it — Apple TV, iPad, iPhone, Mac,
/// Watch — and lets that screen's arrangement be edited from here.
///
/// The board is laid out at the target screen's real point size and then scaled
/// down to fit, so panel text shrinks in proportion: what looks cramped in the
/// simulator will look cramped on the TV.
public struct DeviceSimulatorView: View {
    let model: AppModel
    let dashboardID: Dashboard.ID

    @AppStorage("sb.simulator.device") private var deviceRaw = SBDeviceClass.tv.rawValue
    @AppStorage("sb.simulator.tvSafeGuide") private var showsOverscanGuide = true
    @Environment(\.dismiss) private var dismiss

    private var isEditingLayout: Bool {
        get { model.simulatorEditsLayout }
        nonmutating set { model.simulatorEditsLayout = newValue }
    }

    public init(model: AppModel, dashboardID: Dashboard.ID) {
        self.model = model
        self.dashboardID = dashboardID
    }

    private var device: SBDeviceClass {
        get { SBDeviceClass(rawValue: deviceRaw) ?? .tv }
        nonmutating set { deviceRaw = newValue.rawValue }
    }

    private var board: Dashboard? { model.store.dashboard(id: dashboardID) }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                // Side by side once there's room for a preview and a column of
                // controls; stacked and scrolling on a phone.
                if proxy.size.width >= 820 {
                    HStack(spacing: 0) {
                        stage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(20)
                        Divider()
                        ScrollView {
                            controls.padding(20)
                        }
                        .frame(width: 340)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            stage
                                .frame(height: max(300, proxy.size.height * 0.42))
                            controls
                        }
                        .padding(16)
                    }
                }
            }
            .background(SBTheme.background.opacity(0.6))
            .navigationTitle("Device Preview")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isEditingLayout = false
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 640, idealHeight: 760)
        #else
        .presentationSizing(.page)
        #endif
    }

    // MARK: - Stage

    private var stage: some View {
        VStack(spacing: 12) {
            devicePicker
            GeometryReader { proxy in
                let size = device.nominalPointSize
                let scale = min(proxy.size.width / size.width,
                                proxy.size.height / size.height)
                screen(size: size, scale: scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            Text(device.previewNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var devicePicker: some View {
        Picker("Device", selection: Binding(get: { device },
                                            set: { device = $0 })) {
            ForEach(SBDeviceClass.allCases) { option in
                Label(option.displayName, systemImage: option.symbolName)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func screen(size: CGSize, scale: CGFloat) -> some View {
        BoardView(model: model, dashboardID: dashboardID,
                  layoutTarget: device, isPreview: true,
                  editingOverride: isEditingLayout)
            .frame(width: size.width, height: size.height)
            .overlay {
                if showsOverscanGuide, device.overscanInset != .zero {
                    Rectangle()
                        .strokeBorder(SBTheme.warn.opacity(0.55),
                                      style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                        .padding(.horizontal, device.overscanInset.width)
                        .padding(.vertical, device.overscanInset.height)
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

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            layoutSection
            if device.overscanInset != .zero {
                overscanSection
            }
            gridSection
            panelSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isCustom: Bool { board?.hasCustomLayout(for: device) ?? false }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Layout")
            Text(isCustom
                 ? "\(device.displayName) has its own arrangement. Changes here don't touch your other devices."
                 : "\(device.displayName) follows the board's shared layout, the same one every device without its own arrangement uses.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Edit \(device.displayName) Layout", isOn: Binding(
                get: { isEditingLayout },
                set: { editing in
                    // Touching the layout here must never rewrite the shared
                    // one, so give this device its own copy first.
                    if editing { model.store.beginCustomLayout(in: dashboardID, on: device) }
                    isEditingLayout = editing
                }))
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
                Button("Reset to Shared Layout", role: .destructive) {
                    isEditingLayout = false
                    model.store.resetLayout(in: dashboardID, on: device)
                }
            }
        }
    }

    private var overscanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Overscan")
            Toggle("Show TV-Safe Guide", isOn: $showsOverscanGuide)
                .toggleStyle(.switch)
            Text("Some televisions crop the edges of the picture. Anything outside the dashed line may not be visible on your Apple TV.")
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
            Stepper("Rows: \(grid.rows)") { step(rows: 1) } onDecrement: { step(rows: -1) }
            Text("Panels stretch to fill the grid, so fewer rows means bigger panels.")
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
