import Foundation

/// Shared identifiers. Change these to match your team's App Group /
/// iCloud container if you rename the bundle IDs.
public enum SBIdentifiers {
    public static let appGroup = "group.guru.am.statusboard"
    public static let cloudContainer = "iCloud.guru.am.statusboard"
    public static let bonjourServiceType = "_statusboard._tcp"
    public static let defaultBridgePort: UInt16 = 7311
}

public enum SBStorage {
    /// The App Group container shared with widget extensions, falling back to
    /// Application Support (and finally the temp dir) so unsigned development
    /// builds never crash.
    public static func sharedContainerURL() -> URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SBIdentifiers.appGroup) {
            return url
        }
        return localSupportURL()
    }

    public static func localSupportURL() -> URL {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true))
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("StatusBoard", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
