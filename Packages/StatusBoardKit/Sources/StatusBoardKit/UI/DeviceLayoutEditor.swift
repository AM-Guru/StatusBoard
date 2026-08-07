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

    public init(model: AppModel, dashboardID: Dashboard.ID, device: SBDeviceClass) {
        self.model = model
        self.dashboardID = dashboardID
        self.device = device
    }

    private var board: Dashboard? { model.store.dashboard(id: dashboardID) }

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
            GeometryReader { proxy in
                let size = device.nominalPointSize
                let scale = min(proxy.size.width / size.width,
                                proxy.size.height / size.height)
                screen(size: size, scale: scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        let note = "\(device.displayName) · \(device.previewNote)"
        return model.isEditing
            ? "\(note) — drag panels to arrange this screen"
            : "\(note) — turn on Edit to arrange this screen"
    }

    private func screen(size: CGSize, scale: CGFloat) -> some View {
        // Not a preview: these are the board's real panels, so configuring and
        // refreshing them from here works exactly as it does on the live board.
        // Only the layout being written is different.
        BoardView(model: model, dashboardID: dashboardID, layoutTarget: device)
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

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
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
                 : "\(device.displayName) follows the board's shared layout, the same one every device without its own arrangement uses. Moving a panel here gives it an arrangement of its own.")
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
                Button("Reset to Shared Layout", role: .destructive) {
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
