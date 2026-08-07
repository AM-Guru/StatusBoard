#if os(watchOS)
import SwiftUI
import WatchKit

/// Apple Watch experience. The same boards that appear on the Mac, iPhone,
/// iPad and Apple TV arrive here over iCloud sync — reflowed by
/// ``WatchLayout`` rather than shrunk, so a board stays readable from a 40 mm
/// screen up to a 49 mm one.
///
/// The watch gives up its chrome for the panels: no navigation title, no
/// system clock, no toolbar button. One screenful of board at a time, turned
/// with the crown, and a press and hold anywhere for settings.
public struct WatchRootView: View {
    @Bindable var model: AppModel
    @State private var showsSettings = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            WatchBoardPager(model: model)
                .containerBackground(.black, for: .navigation)
                .toolbar(.hidden, for: .navigationBar)
                // The watch draws its clock above the navigation bar, so
                // hiding the bar alone still leaves the time over the board.
                // `_statusBarHidden` is watchOS's only door to it — SwiftUI
                // ships no un-prefixed spelling on this platform (the
                // `.toolbar(_:for: .statusBar)` replacement is iOS-only), and
                // it is declared in SwiftUI's public interface for watchOS 6
                // and later.
                ._statusBarHidden()
                .ignoresSafeArea()
                // Simultaneous so the crown and the page swipes keep working.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        WKInterfaceDevice.current().play(.click)
                        showsSettings = true
                    }
                )
                // VoiceOver cannot press and hold, so it gets the same door
                // as a rotor action.
                .accessibilityAction(named: Text("Settings")) { showsSettings = true }
                .sheet(isPresented: $showsSettings) {
                    WatchSettingsView(model: model)
                }
        }
        .tint(SBTheme.accent)
    }
}

// MARK: - Board

/// One screenful of board per page, in the order the board reads, minus
/// anything hidden on the watch. Every dashboard follows the one before it, so
/// the crown walks the whole collection without ever leaving the panels.
struct WatchBoardPager: View {
    let model: AppModel
    @State private var selection: Panel.ID?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let pages = pages(forScreenWidth: size.width)

            Group {
                if pages.isEmpty {
                    WatchEmptyState()
                        .frame(width: size.width, height: size.height)
                } else {
                    TabView(selection: $selection) {
                        ForEach(pages) { page in
                            WatchPageView(model: model, page: page)
                                .frame(width: size.width, height: size.height)
                                .tag(Optional(page.id))
                        }
                    }
                    .tabViewStyle(.verticalPage)
                }
            }
            // A board arriving over iCloud can retire the page we were on;
            // land on the first one rather than an empty screen.
            .onChange(of: pages.map(\.id)) { _, ids in
                if selection == nil || !ids.contains(selection!) { selection = ids.first }
            }
            .onAppear { if selection == nil { selection = pages.first?.id } }
            .onChange(of: selection) { _, id in refresh(pageID: id, in: pages) }
        }
        .ignoresSafeArea()
    }

    /// The watch's own arrangement of every board: a single column by default,
    /// pairing small panels up on the sizes wide enough to keep them legible.
    private func pages(forScreenWidth width: CGFloat) -> [WatchPage] {
        let widthClass = WatchLayout.width(forScreenWidth: width)
        return model.store.dashboards.flatMap { board in
            WatchLayout.rows(for: board.panelsInReadingOrder(for: .watch),
                             boardColumns: board.grid(for: .watch).columns,
                             width: widthClass)
                .compactMap { WatchPage(panels: $0) }
        }
    }

    /// Turning to a page asks its panels for fresh data, the way opening a
    /// panel used to.
    private func refresh(pageID: Panel.ID?, in pages: [WatchPage]) {
        guard let page = pages.first(where: { $0.id == pageID }) else { return }
        for panel in page.panels where panel.kind.isFetched {
            model.engine.refreshNow(panel: panel)
        }
    }
}

/// A row of the reflowed board, identified by its first panel so that pages
/// keep their place across a sync.
struct WatchPage: Identifiable {
    let id: Panel.ID
    let panels: [Panel]

    init?(panels: [Panel]) {
        guard let first = panels.first else { return nil }
        self.id = first.id
        self.panels = panels
    }
}

/// One page, rendered with the same ``PanelView`` every other platform uses so
/// all panel kinds stay in sync — edge to edge, filling the display.
struct WatchPageView: View {
    let model: AppModel
    let page: WatchPage

    var body: some View {
        HStack(spacing: 3) {
            ForEach(page.panels) { panel in
                PanelView(panel: panel, record: model.snapshots.record(for: panel.snapshotKey))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct WatchEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SBTheme.accent)
            Text("No boards yet")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("Build a board on your iPhone or Mac and it appears here over iCloud.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Settings

/// Everything the board no longer shows: the index of every panel, and the
/// refresh the toolbar used to hold. Reached by pressing and holding the
/// board.
struct WatchSettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        for board in model.store.dashboards {
                            for panel in board.panels where panel.kind.isFetched {
                                model.engine.refreshNow(panel: panel)
                            }
                        }
                        dismiss()
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
                WatchPanelIndexSections(model: model)
            }
            .navigationTitle("Settings")
        }
        .tint(SBTheme.accent)
    }
}

// MARK: - Index

struct WatchPanelIndexSections: View {
    let model: AppModel

    var body: some View {
        ForEach(model.store.dashboards) { board in
            Section(board.name) {
                ForEach(board.panels) { panel in
                    NavigationLink {
                        WatchPanelDetailView(model: model, panel: panel)
                    } label: {
                        WatchPanelRow(panel: panel,
                                      record: model.snapshots.record(for: panel.snapshotKey))
                    }
                }
            }
        }
    }
}

struct WatchPanelRow: View {
    let panel: Panel
    let record: SnapshotRecord?

    var summary: String {
        switch record?.snapshot {
        case .number(let value, let unit):
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return unit.map { "\(text) \($0)" } ?? text
        case .series(let series):
            return series.points.last.map { String(format: "%.1f", $0.value) } ?? "—"
        case .text(let text):
            return String(text.prefix(24))
        case .weather(let report):
            return "\(Int(report.temperatureC.rounded()))° \(report.conditionDescription)"
        case .statuses(let statuses):
            let down = statuses.filter { $0.state == .down }.count
            return down == 0 ? "All up" : "\(down) down"
        case .feed(let items):
            return items.first.map { String($0.title.prefix(24)) } ?? "—"
        case .error:
            return "⚠︎"
        default:
            return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: panel.kind.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(panel.settings.accentColor ?? SBTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(panel.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct WatchPanelDetailView: View {
    let model: AppModel
    let panel: Panel

    var body: some View {
        PanelView(panel: panel, record: model.snapshots.record(for: panel.snapshotKey))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(panel.title)
            .onAppear {
                if panel.kind.isFetched { model.engine.refreshNow(panel: panel) }
            }
    }
}
#endif
