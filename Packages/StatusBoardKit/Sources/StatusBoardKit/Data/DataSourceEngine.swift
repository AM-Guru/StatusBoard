import Foundation
import Observation

/// Schedules periodic fetches for every panel that pulls remote data and
/// writes results into the `SnapshotStore`.
@MainActor
public final class DataSourceEngine {
    private let snapshots: SnapshotStore
    private var tasks: [String: Task<Void, Never>] = [:]
    private var fingerprints: [String: Panel] = [:]

    /// Used by web clip panels on tvOS to ask the Mac bridge for a rendering.
    public weak var bridgeClient: BridgeClient?

    public init(snapshots: SnapshotStore) {
        self.snapshots = snapshots
    }

    /// Reconciles running fetch loops with the current set of panels.
    public func rebuild(panels: [Panel]) {
        var seen = Set<String>()
        for panel in panels where panel.kind.isFetched {
            let key = panel.snapshotKey
            seen.insert(key)
            if let existing = fingerprints[key], existing.kind == panel.kind,
               existing.settings == panel.settings {
                continue
            }
            fingerprints[key] = panel
            tasks[key]?.cancel()
            tasks[key] = makeLoop(for: panel)
        }
        for (key, task) in tasks where !seen.contains(key) {
            task.cancel()
            tasks[key] = nil
            fingerprints[key] = nil
        }
    }

    public func refreshNow(panel: Panel) {
        Task { await fetchAndStore(panel: panel) }
    }

    public func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        fingerprints.removeAll()
    }

    private func makeLoop(for panel: Panel) -> Task<Void, Never> {
        let interval = max(15, panel.settings.refreshSeconds)
        return Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchAndStore(panel: panel)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Appends a sampled value to the panel's stored series so single-number
    /// sources build up a chartable history over time.
    private func appendToHistory(_ value: Double, unit: String?, key: String,
                                 limit: Int = 200) -> DataSnapshot {
        var points: [SeriesPoint] = []
        if case .series(let existing)? = snapshots.record(for: key)?.snapshot {
            points = existing.points
        }
        points.append(SeriesPoint(date: Date(), value: value))
        if points.count > limit { points.removeFirst(points.count - limit) }
        return .series(SeriesData(points: points, unit: unit))
    }

    private func fetchAndStore(panel: Panel) async {
        let snapshot = await fetch(panel: panel)
        guard !Task.isCancelled, let snapshot else { return }
        snapshots.set(snapshot, for: panel.snapshotKey)
    }

    private func fetch(panel: Panel) async -> DataSnapshot? {
        switch panel.kind {
        case .weather:
            return await WeatherSource.fetch(settings: panel.settings)
        case .feed:
            return await FeedParser.fetch(settings: panel.settings)
        case .calendar:
            return await CalendarSource.fetch(settings: panel.settings)
        case .image:
            return await ImageSource.fetch(settings: panel.settings)
        case .table:
            return await WebQuerySource.table(settings: panel.settings)
        case .status:
            return await StatusSource.fetch(settings: panel.settings)
        case .graph:
            // Graphs fed by the bridge are passive; only fetch when a URL is set.
            guard panel.settings.url != nil else { return nil }
            // A series path charts the response directly; a value path samples
            // one number per refresh and charts its accumulated history.
            if let seriesPath = panel.settings.seriesPath, !seriesPath.isEmpty {
                return await WebQuerySource.series(settings: panel.settings)
            }
            if let valuePath = panel.settings.valuePath, !valuePath.isEmpty {
                let value = await WebQuerySource.value(settings: panel.settings)
                guard case .number(let number, let unit) = value else { return value }
                return appendToHistory(number, unit: unit, key: panel.snapshotKey)
            }
            return await WebQuerySource.series(settings: panel.settings)
        case .progress:
            // Progress fed by the bridge is passive; only fetch when a URL is set.
            guard panel.settings.url != nil else { return nil }
            return await WebQuerySource.value(settings: panel.settings)
        case .mcp:
            return await MCPSource.fetch(settings: panel.settings)
        case .github:
            return await GitHubSource.fetch(settings: panel.settings)
        case .appStoreConnect:
            return await AppStoreConnectSource.fetch(settings: panel.settings)
        case .supabase:
            return await SupabaseSource.fetch(settings: panel.settings)
        case .logs:
            return await LogAnalyticsSource.fetch(settings: panel.settings)
        case .health:
            return await HealthSource.fetch(settings: panel.settings)
        case .canvas:
            return await CanvasSource.fetch(settings: panel.settings)
        case .k12schedule:
            return await K12OLSSource.fetch(settings: panel.settings)
        case .grades:
            return await GradesSource.fetch(settings: panel.settings)
        case .schedule:
            return await ScheduleSource.fetch(settings: panel.settings)
        case .assignments:
            return await AssignmentsSource.fetch(settings: panel.settings)
        case .tessie:
            return await TessieSource.fetch(settings: panel.settings)
        case .homeKit:
            // Returns nil for a live camera panel — HomeKit hands over a view,
            // not an image, so the panel renders it and there is nothing to
            // store. Leaving the old snapshot alone is the right behaviour.
            return await HomeKitSource.fetch(settings: panel.settings)
        case .homeAssistant:
            return await HomeAssistantSource.fetch(settings: panel.settings)
        case .nest:
            return await NestSource.fetch(settings: panel.settings)
        case .webClip:
            #if os(tvOS)
            // No WebKit on tvOS — ask the Mac bridge for an offscreen rendering.
            guard let urlString = panel.settings.url else { return .error("No URL configured") }
            guard let client = bridgeClient, client.isConnected else {
                return .error("Connect the Mac bridge to show web clips on Apple TV")
            }
            let spec = WebClipSpec(url: urlString, settings: panel.settings)
            if let png = await client.requestWebClip(spec: spec) {
                return .image(png)
            }
            return .error("Bridge could not render \(urlString)")
            #else
            // Live WKWebView renders in-panel; nothing to fetch.
            return nil
            #endif
        case .clock, .countdown, .text, .bridge:
            return nil
        }
    }
}
