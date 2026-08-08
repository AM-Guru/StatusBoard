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

    /// How long to wait before trying again after a fetch that came back with
    /// an error, in place of the panel's own interval.
    ///
    /// A panel's interval is how often its data goes stale, not how long a
    /// failure deserves to sit on screen. The first fetch happens the moment the
    /// app launches, which is exactly when the network is least likely to be up
    /// and a lapsed sign-in has not yet renewed itself — and a five-minute panel
    /// showed that first failure for five minutes.
    private nonisolated static let retryDelay: TimeInterval = 5
    /// How many quick retries a panel gets before it settles back onto its own
    /// interval. Enough to ride out a launch, not enough to hammer a portal
    /// that is genuinely down.
    private nonisolated static let maxQuickRetries = 3

    /// How long to wait before the next fetch: a short retry while a run of
    /// failures is still young, otherwise the panel's own interval.
    nonisolated static func delay(afterFailures failures: Int,
                                  interval: TimeInterval) -> TimeInterval {
        guard failures > 0, failures <= maxQuickRetries else { return interval }
        return min(retryDelay, interval)
    }

    private func makeLoop(for panel: Panel) -> Task<Void, Never> {
        let interval = max(15, panel.settings.refreshSeconds)
        return Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let succeeded = await self?.fetchAndStore(panel: panel) ?? true
                failures = succeeded ? 0 : failures + 1
                try? await Task.sleep(
                    for: .seconds(Self.delay(afterFailures: failures, interval: interval)))
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

    /// Fetches a panel and stores the result, reporting whether it worked so the
    /// loop can decide between a quick retry and the panel's own interval.
    ///
    /// Panels that render themselves — a live web clip, a HomeKit camera — hand
    /// back nothing to store and count as success: there is no failure to retry.
    @discardableResult
    private func fetchAndStore(panel: Panel) async -> Bool {
        let snapshot = await fetch(panel: panel)
        guard !Task.isCancelled else { return true }
        guard let snapshot else { return true }
        snapshots.set(snapshot, for: panel.snapshotKey)
        if case .error = snapshot { return false }
        return true
    }

    /// Runs a K12-backed fetch, falling back to the Mac bridge when this device
    /// couldn't do it itself.
    ///
    /// On Apple TV that is the normal case rather than an edge one: the portal
    /// hands out sessions through a web view, and tvOS has no WebKit. The TV
    /// still tries first — a session synced from iPhone or Mac through the
    /// private iCloud database is usually enough — and only asks the Mac when
    /// that comes back with nothing.
    private func k12(settings: PanelSettings,
                     _ local: () async -> DataSnapshot) async -> DataSnapshot {
        let snapshot = await local()
        #if os(tvOS)
        guard case .error = snapshot else { return snapshot }
        guard let bridgeClient, bridgeClient.isConnected else { return snapshot }
        let connector = settings.connector ?? ConnectorConfig()
        let portal = connector.projectURL?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? connector.projectURL! : K12Session.defaultPortal
        // Whatever the Mac says wins, including its error: it's the device that
        // owns the sign-in, so its explanation is the more useful one. Only a
        // bridge that didn't answer at all leaves the local error standing.
        return await bridgeClient.requestK12(portal: portal, mode: connector.mode) ?? snapshot
        #else
        return snapshot
        #endif
    }

    private func fetch(panel: Panel) async -> DataSnapshot? {
        switch panel.kind {
        case .weather:
            return await WeatherSource.fetch(settings: panel.settings)
        case .feed:
            return await FeedParser.fetch(settings: panel.settings)
        case .calendar:
            #if os(tvOS)
            // tvOS cannot read EventKit. Once a Mac bridge is connected, keep
            // the last relayed Calendar snapshot instead of overwriting it with
            // a local "unavailable" error every retry interval.
            if bridgeClient?.isConnected == true { return nil }
            if case .feed? = snapshots.record(for: panel.snapshotKey)?.snapshot { return nil }
            #endif
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
            #if os(macOS) || os(tvOS)
            if let existing = snapshots.record(for: panel.snapshotKey),
               !existing.snapshot.isError { return nil }
            #endif
            return await HealthSource.fetch(settings: panel.settings)
        case .canvas:
            return await CanvasSource.fetch(settings: panel.settings)
        case .k12schedule:
            return await k12(settings: panel.settings) {
                await K12OLSSource.fetch(settings: panel.settings)
            }
        case .grades:
            return await GradesSource.fetch(settings: panel.settings)
        case .schedule:
            return await k12(settings: panel.settings) {
                await ScheduleSource.fetch(settings: panel.settings)
            }
        case .assignments:
            return await AssignmentsSource.fetch(settings: panel.settings)
        case .tessie:
            return await TessieSource.fetch(settings: panel.settings)
        case .homeKit:
            #if os(macOS)
            if let existing = snapshots.record(for: panel.snapshotKey),
               !existing.snapshot.isError { return nil }
            #endif
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
