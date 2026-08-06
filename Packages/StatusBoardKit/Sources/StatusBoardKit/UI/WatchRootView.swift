#if os(watchOS)
import SwiftUI

/// Apple Watch experience. The same boards that appear on the Mac, iPhone,
/// iPad and Apple TV arrive here over iCloud sync — reflowed by
/// ``WatchLayout`` rather than shrunk, so a board stays readable from a 40 mm
/// screen up to a 49 mm one. Two ways to read it: the board itself, or a
/// compact index of every panel.
public struct WatchRootView: View {
    @Bindable var model: AppModel
    @State private var showsIndex = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if showsIndex {
                    WatchPanelIndex(model: model)
                } else {
                    WatchBoardScroll(model: model)
                }
            }
            .navigationTitle(showsIndex ? "All Panels" : "Status Board")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { showsIndex.toggle() }
                    } label: {
                        Image(systemName: showsIndex ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityLabel(showsIndex ? "Show boards" : "Show all panels")
                }
            }
        }
        .tint(SBTheme.accent)
    }
}

// MARK: - Board

/// Every dashboard, stacked. Vertical scrolling only, so it never fights the
/// system's edge-swipe back gesture.
struct WatchBoardScroll: View {
    let model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let screenWidth = proxy.size.width
            let widthClass = WatchLayout.width(forScreenWidth: screenWidth)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.store.dashboards.isEmpty {
                        WatchEmptyState()
                    }
                    ForEach(model.store.dashboards) { board in
                        if model.store.dashboards.count > 1 {
                            Text(board.name.uppercased())
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                        ForEach(Array(rows(for: board, widthClass: widthClass).enumerated()),
                                id: \.offset) { _, row in
                            HStack(spacing: 6) {
                                ForEach(row) { panel in
                                    WatchTile(model: model,
                                              panel: panel,
                                              height: WatchLayout.tileHeight(
                                                forScreenWidth: screenWidth,
                                                isFullWidth: row.count == 1))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 8)
            }
        }
    }

    private func rows(for board: Dashboard, widthClass: WatchLayout.Width) -> [[Panel]] {
        WatchLayout.rows(for: board.panels,
                         boardColumns: board.grid.columns,
                         width: widthClass)
    }
}

/// One panel, rendered with the same ``PanelView`` every other platform uses
/// so all panel kinds stay in sync — just constrained to a watch-sized tile.
struct WatchTile: View {
    let model: AppModel
    let panel: Panel
    let height: CGFloat

    var body: some View {
        NavigationLink {
            WatchPanelDetailView(model: model, panel: panel)
        } label: {
            PanelView(panel: panel, record: model.snapshots.record(for: panel.snapshotKey))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Index

struct WatchPanelIndex: View {
    let model: AppModel

    var body: some View {
        List {
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
