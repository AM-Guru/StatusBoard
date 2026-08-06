import Foundation
import Network
import Observation

/// Discovers Status Board bridges on the local network via Bonjour and holds a
/// live subscription: every snapshot the Mac pushes lands here in real time.
@MainActor
@Observable
public final class BridgeClient {
    public struct DiscoveredBridge: Identifiable, Hashable {
        public var id: String { name }
        public var name: String
        let endpoint: NWEndpoint
    }

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(serverName: String)
    }

    public private(set) var discovered: [DiscoveredBridge] = []
    public private(set) var connectionState: ConnectionState = .disconnected
    /// When true, automatically connect to the first bridge that appears.
    public var autoConnect = true

    @ObservationIgnored public var onSnapshot: ((String, SnapshotRecord) -> Void)?
    /// Fired when a subscription reaches the connected state.
    @ObservationIgnored public var onConnect: (() -> Void)?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var pendingWebClips: [String: CheckedContinuation<Data?, Never>] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    public init() {}

    public var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    // MARK: - Discovery

    public func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: SBIdentifiers.bonjourServiceType, domain: nil),
            using: NWParameters.tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.discovered = results.compactMap { result in
                    if case .service(let name, _, _, _) = result.endpoint {
                        return DiscoveredBridge(name: name, endpoint: result.endpoint)
                    }
                    return nil
                }.sorted { $0.name < $1.name }
                if self.autoConnect, self.connection == nil,
                   let first = self.discovered.first {
                    self.connect(to: first)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        reconnectTask?.cancel()
        browser?.cancel()
        browser = nil
        disconnect()
    }

    // MARK: - Connection

    public func connect(to bridge: DiscoveredBridge) {
        disconnect()
        connectionState = .connecting
        let connection = NWConnection(to: bridge.endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    var handshake = Data(BridgeMessage.subscribeHandshake.utf8)
                    handshake.append(0x0A)
                    connection.send(content: handshake, completion: .contentProcessed { _ in })
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.handleDisconnect()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        connectionState = .disconnected
        for continuation in pendingWebClips.values {
            continuation.resume(returning: nil)
        }
        pendingWebClips.removeAll()
    }

    private func handleDisconnect() {
        let wasConnected = isConnected
        disconnect()
        guard wasConnected, autoConnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let first = self.discovered.first else { return }
            self.connect(to: first)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainLines()
                }
                if isComplete || error != nil {
                    self.handleDisconnect()
                } else if self.connection === connection {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = BridgeMessage.decodeLine(line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message {
        case .hello(let serverName):
            connectionState = .connected(serverName: serverName)
            onConnect?()
        case .snapshot(let key, let record):
            onSnapshot?(key, record)
        case .webClipResponse(let id, let pngBase64, _):
            let data = pngBase64.flatMap { Data(base64Encoded: $0) }
            pendingWebClips.removeValue(forKey: id)?.resume(returning: data)
        case .webClipRequest:
            break
        }
    }

    /// Asks the Mac bridge to render a web page (used on tvOS).
    public func requestWebClip(spec: WebClipSpec) async -> Data? {
        guard isConnected, let connection else { return nil }
        let id = UUID().uuidString
        let message = BridgeMessage.webClipRequest(id: id, spec: spec)
        guard let data = message.encodedLine() else { return nil }

        return await withCheckedContinuation { continuation in
            pendingWebClips[id] = continuation
            connection.send(content: data, completion: .contentProcessed { _ in })
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.pendingWebClips.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }
}
