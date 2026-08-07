import SwiftUI
import Observation

/// One shared cache of background images, keyed by URL.
///
/// Shared on purpose: several panels can mask the *same* board picture, and
/// they only line up if they are all drawing pixel-identical bytes. A per-view
/// `AsyncImage` would fetch (and decode, and possibly resize) separately.
@MainActor
@Observable
public final class SBBackdropImageStore {
    public static let shared = SBBackdropImageStore()

    private var images: [String: SBPlatformImage] = [:]
    private var failed: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let cacheDirectory: URL?

    init() {
        let base = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        cacheDirectory = base?.appendingPathComponent("StatusBoardBackdrops", isDirectory: true)
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory,
                                                     withIntermediateDirectories: true)
        }
    }

    /// The image for a URL, starting a download the first time it's asked for.
    /// Returns nil until it arrives; the view re-renders when it does.
    public func image(for urlString: String?) -> SBPlatformImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let cached = images[urlString] { return cached }
        guard !failed.contains(urlString), !inFlight.contains(urlString) else { return nil }
        guard let url = URL(string: urlString), url.scheme != nil else {
            failed.insert(urlString)
            return nil
        }
        if let onDisk = diskURL(for: urlString), let data = try? Data(contentsOf: onDisk),
           let image = SBPlatformImage(data: data) {
            images[urlString] = image
            return image
        }
        inFlight.insert(urlString)
        Task { await load(url: url, key: urlString) }
        return nil
    }

    /// Drops a cached image so the next draw refetches it — used when the user
    /// re-enters the same URL after replacing the file behind it.
    public func forget(_ urlString: String) {
        images[urlString] = nil
        failed.remove(urlString)
        if let onDisk = diskURL(for: urlString) {
            try? FileManager.default.removeItem(at: onDisk)
        }
    }

    private func load(url: URL, key: String) async {
        defer { inFlight.remove(key) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = SBPlatformImage(data: data) else {
            failed.insert(key)
            return
        }
        images[key] = image
        if let onDisk = diskURL(for: key) {
            try? data.write(to: onDisk, options: .atomic)
        }
    }

    private func diskURL(for key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        // A stable, filesystem-safe name. Not a security hash — just a key.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return cacheDirectory.appendingPathComponent(String(hash, radix: 16), conformingTo: .data)
    }
}

#if os(macOS)
public typealias SBPlatformImage = NSImage
#else
public typealias SBPlatformImage = UIImage
#endif

extension Image {
    init(sbImage: SBPlatformImage) {
        #if os(macOS)
        self.init(nsImage: sbImage)
        #else
        self.init(uiImage: sbImage)
        #endif
    }
}

/// A background image from a URL, fitted as asked. Draws nothing until the
/// image has loaded, so a slow download never blanks the panel behind it.
struct SBBackdropImageView: View {
    let urlString: String?
    let fill: BackgroundImageFill

    private var store: SBBackdropImageStore { SBBackdropImageStore.shared }

    var body: some View {
        GeometryReader { proxy in
            if let image = store.image(for: urlString) {
                switch fill {
                case .fill:
                    Image(sbImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                case .fit:
                    Image(sbImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                case .tile:
                    Image(sbImage: image)
                        .resizable(resizingMode: .tile)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                Color.clear
            }
        }
    }
}
