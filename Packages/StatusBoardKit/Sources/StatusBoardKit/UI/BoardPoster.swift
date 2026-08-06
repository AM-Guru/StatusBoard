#if !os(tvOS) && !os(watchOS)
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// `isStaticRender` lives in StaticRender.swift, outside this file's platform
// guard, because the views that consult it are shared with tvOS and watchOS.

/// Shareable board poster — renders the board to a 1080p PNG on demand when
/// the user picks a share destination.
public struct BoardPoster: Transferable {
    public let board: Dashboard
    public let records: [String: SnapshotRecord]

    public init(board: Dashboard, records: [String: SnapshotRecord]) {
        self.board = board
        self.records = records
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { poster in
            let url = try await poster.renderPNG()
            return SentTransferredFile(url)
        }
    }

    @MainActor
    public func renderPNG(size: CGSize = CGSize(width: 1920, height: 1080)) throws -> URL {
        let view = BoardPosterView(board: board, records: records, size: size)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            throw SBError.message("Could not render the board")
        }
        let data = try Self.pngData(from: cgImage)
        let name = board.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func pngData(from cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw SBError.message("Could not encode PNG")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SBError.message("Could not encode PNG")
        }
        return data as Data
    }
}

/// A static, non-interactive replica of BoardView used for image export.
struct BoardPosterView: View {
    let board: Dashboard
    let records: [String: SnapshotRecord]
    let size: CGSize

    private let spacing: CGFloat = 12

    var body: some View {
        let cellWidth = (size.width - spacing) / CGFloat(board.grid.columns)
        let cellHeight = (size.height - spacing) / CGFloat(board.grid.rows)
        ZStack(alignment: .topLeading) {
            SBTheme.background
            ForEach(board.panels) { panel in
                let frame = panel.frame
                PanelView(panel: panel, record: records[panel.snapshotKey])
                    .frame(width: CGFloat(frame.width) * cellWidth - spacing,
                           height: CGFloat(frame.height) * cellHeight - spacing)
                    .offset(x: CGFloat(frame.x) * cellWidth + spacing,
                            y: CGFloat(frame.y) * cellHeight + spacing)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.isStaticRender, true)
        .environment(\.colorScheme, .dark)
    }
}
#endif
