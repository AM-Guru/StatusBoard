import Foundation

/// Keeps a rolling history of thermostat samples, one file per panel.
///
/// None of the three services offers usable history: HomeKit has no concept
/// of it at all, Nest's API returns only the present, and Home Assistant's
/// recorder is optional and may be minutes coarse. So every refresh appends
/// one sample here, and the trend chart and `HVACAnalyzer` read it back.
///
/// It lives in the App Group container beside the snapshots — never in
/// iCloud. A month of one-minute samples is a few hundred kilobytes of
/// household telemetry, and the sync engine deliberately carries only board
/// configuration.
public actor HVACHistoryStore {
    public static let shared = HVACHistoryStore()

    /// A week is enough for weather to change and for a fault to repeat,
    /// and short enough that the file stays small.
    static let retention: TimeInterval = 7 * 24 * 3600
    /// A hard ceiling as well, in case someone sets a ten-second refresh.
    static let maxSamples = 6000
    /// Samples closer together than this are dropped. Two panels pointed at
    /// the same thermostat share a file, so without this a second panel
    /// doubles the sample rate and halves every measured run length.
    static let minimumSpacing: TimeInterval = 20

    private var cache: [String: [HVACSample]] = [:]

    private init() {}

    private static var directory: URL {
        let url = SBStorage.sharedContainerURL().appendingPathComponent("hvac", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Files are keyed by the *device*, not the panel, so a thermostat panel
    /// and a trend panel watching the same unit build one shared history
    /// instead of two half-length ones.
    static func fileURL(for key: String) -> URL {
        let safe = key.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return directory.appendingPathComponent("\(String(safe).prefix(120)).json")
    }

    /// Records a sample and returns the trimmed history, newest last.
    @discardableResult
    public func record(_ sample: HVACSample, for key: String) -> [HVACSample] {
        var samples = load(key)
        if let last = samples.last, sample.date.timeIntervalSince(last.date) < Self.minimumSpacing {
            // Too soon to be a new observation — keep the fresher values but
            // don't lengthen the history.
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        samples = trim(samples)
        cache[key] = samples
        SBStorage.write(samples, to: Self.fileURL(for: key))
        return samples
    }

    /// Merges samples the provider already had (Home Assistant's recorder) in
    /// under whatever has been recorded locally, so a panel added today can
    /// still draw yesterday. Existing samples win on ties: they came from
    /// this app and carry the fields the backfill may lack.
    @discardableResult
    public func backfill(_ incoming: [HVACSample], for key: String) -> [HVACSample] {
        guard !incoming.isEmpty else { return load(key) }
        let existing = load(key)
        let known = Set(existing.map { $0.date.timeIntervalSince1970.rounded() })
        let fresh = incoming.filter { !known.contains($0.date.timeIntervalSince1970.rounded()) }
        guard !fresh.isEmpty else { return existing }
        let merged = trim((existing + fresh).sorted { $0.date < $1.date })
        cache[key] = merged
        SBStorage.write(merged, to: Self.fileURL(for: key))
        return merged
    }

    public func history(for key: String) -> [HVACSample] { load(key) }

    /// Whether it is worth asking a provider for backfill — only when there
    /// is nothing much here yet, so a working panel never re-downloads.
    public func needsBackfill(for key: String) -> Bool {
        load(key).count < 10
    }

    public func clear(for key: String) {
        cache[key] = nil
        try? FileManager.default.removeItem(at: Self.fileURL(for: key))
    }

    private func load(_ key: String) -> [HVACSample] {
        if let cached = cache[key] { return cached }
        let samples = SBStorage.read([HVACSample].self, from: Self.fileURL(for: key)) ?? []
        cache[key] = samples
        return samples
    }

    private func trim(_ samples: [HVACSample]) -> [HVACSample] {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        var trimmed = samples.filter { $0.date >= cutoff }
        if trimmed.count > Self.maxSamples {
            trimmed.removeFirst(trimmed.count - Self.maxSamples)
        }
        return trimmed
    }
}
