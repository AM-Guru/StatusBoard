#if os(macOS)
import Foundation
import Network
import Observation

/// The macOS "bridge": a Bonjour-advertised TCP listener that accepts
///  - HTTP requests (curl / shell scripts / AI tools pushing data), and
///  - long-lived subscription connections from iPhone/iPad/Apple TV apps,
/// relaying every pushed snapshot to all subscribers in real time.
@MainActor
@Observable
public final class BridgeServer {
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    public private(set) var subscriberCount = 0
    public private(set) var log: [String] = []
    public var port: UInt16 = SBIdentifiers.defaultBridgePort
    /// Optional shared-secret; when set, pushes must carry X-StatusBoard-Token.
    public var token: String = ""
    /// Publish this Mac's CPU/memory/disk/network under mac.* keys.
    public var publishesSystemMetrics = true

    /// Snapshots pushed through the bridge, keyed with the "bridge/" prefix.
    public private(set) var records: [String: SnapshotRecord] = [:]

    /// Feeds the local Mac app's snapshot store.
    @ObservationIgnored public var onSnapshot: ((String, SnapshotRecord) -> Void)?
    /// Supplies this Mac's boards to subscribing displays. Set by AppModel;
    /// while it's nil the bridge behaves exactly as it did before and sends
    /// snapshots only.
    @ObservationIgnored public var boardProvider: (() -> [Dashboard])?

    @ObservationIgnored private var listener: NWListener?
    /// All open connections (HTTP and subscribers) — retained until closed.
    @ObservationIgnored private var connections: [ObjectIdentifier: BridgeServerConnection] = [:]
    @ObservationIgnored private var subscribers: [ObjectIdentifier: BridgeServerConnection] = [:]
    @ObservationIgnored private var histories: [String: [SeriesPoint]] = [:]
    @ObservationIgnored private lazy var systemMetrics = SystemMetricsPublisher(server: self)

    public init() {}

    public func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters,
                                          on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Status Board Bridge",
                type: SBIdentifiers.bonjourServiceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                        self?.append(log: "Bridge listening on port \(self?.port ?? 0)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                        self?.append(log: "Bridge failed: \(error.localizedDescription)")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            systemMetrics.start()
        } catch {
            lastError = error.localizedDescription
            append(log: "Bridge failed to start: \(error.localizedDescription)")
        }
    }

    public func stop() {
        systemMetrics.stop()
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        subscribers.removeAll()
        subscriberCount = 0
        isRunning = false
        append(log: "Bridge stopped")
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = BridgeServerConnection(connection: nwConnection, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    // MARK: - Connection callbacks (main actor)

    func connectionDidSubscribe(_ connection: BridgeServerConnection) {
        subscribers[ObjectIdentifier(connection)] = connection
        subscriberCount = subscribers.count
        append(log: "Device subscribed (\(subscribers.count) connected)")
        connection.send(.hello(serverName: Host.current().localizedName ?? "Mac"))
        if let boards = boardProvider?() {
            connection.send(.boards(boards))
            append(log: "Sent \(boards.count) board\(boards.count == 1 ? "" : "s") to device")
        }
        for (key, record) in records {
            connection.send(.snapshot(key: key, record: record))
        }
    }

    /// Pushes the current board set to every subscribed display. Called when a
    /// board is created, edited or deleted on this Mac, so a wall display
    /// follows along without waiting on iCloud.
    public func publishBoards() {
        guard !subscribers.isEmpty, let boards = boardProvider?() else { return }
        for connection in subscribers.values {
            connection.send(.boards(boards))
        }
    }

    func connectionDidClose(_ connection: BridgeServerConnection) {
        connections[ObjectIdentifier(connection)] = nil
        if subscribers.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            subscriberCount = subscribers.count
            append(log: "Device disconnected (\(subscribers.count) connected)")
        }
    }

    func handleSubscriberMessage(_ message: BridgeMessage, from connection: BridgeServerConnection) {
        guard case .webClipRequest(let id, let spec) = message else { return }
        append(log: "Rendering web clip for device: \(spec.url)")
        Task { @MainActor in
            do {
                let png = try await WebClipRenderer.shared.render(spec: spec)
                connection.send(.webClipResponse(id: id,
                                                 pngBase64: png.base64EncodedString(),
                                                 error: nil))
            } catch {
                connection.send(.webClipResponse(id: id, pngBase64: nil,
                                                 error: error.localizedDescription))
            }
        }
    }

    // MARK: - HTTP handling

    func handleHTTPRequest(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/health"):
            return .json(["ok": .bool(true),
                          "subscribers": .number(Double(subscriberCount)),
                          "keys": .number(Double(records.count))])

        case ("GET", "/api/log"):
            return .json(["log": .array(log.suffix(50).map { JSONValue.string($0) })])

        case ("GET", "/api/keys"):
            let keys = records.keys.sorted().map { JSONValue.string($0) }
            return .json(["keys": .array(keys)])

        case ("POST", "/api/push"):
            if !token.isEmpty, request.headers["x-statusboard-token"] != token {
                return HTTPResponse(status: 401, body: "unauthorized")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let body = request.body,
                  let push = try? decoder.decode(BridgePushRequest.self, from: body) else {
                return HTTPResponse(status: 400, body: "expected JSON: {\"key\":\"cpu\",\"number\":42}")
            }
            apply(push)
            return .json(["ok": .bool(true), "key": .string(BridgeKeys.prefixed(push.key))])

        default:
            return HTTPResponse(status: 404, body: "not found")
        }
    }

    public func apply(_ push: BridgePushRequest, quiet: Bool = false) {
        guard let snapshot = push.primarySnapshot() else {
            append(log: "Push for '\(push.key)' had no payload")
            return
        }
        publish(snapshot, forKey: push.key)

        // Rolling numeric history → "<key>.history" series for graph panels.
        if case .number(let value, let unit) = snapshot {
            let historyLimit = push.history ?? 120
            if historyLimit > 0 {
                let historyKey = push.key + ".history"
                var points = histories[historyKey] ?? []
                points.append(SeriesPoint(date: Date(), value: value))
                if points.count > historyLimit {
                    points.removeFirst(points.count - historyLimit)
                }
                histories[historyKey] = points
                publish(.series(SeriesData(points: points, unit: unit)), forKey: historyKey)
            }
        }
        if !quiet { append(log: "Push: \(push.key)") }
    }

    private func publish(_ snapshot: DataSnapshot, forKey rawKey: String) {
        let key = BridgeKeys.prefixed(rawKey)
        let record = SnapshotRecord(snapshot: snapshot)
        records[key] = record
        onSnapshot?(key, record)
        for connection in subscribers.values {
            connection.send(.snapshot(key: key, record: record))
        }
    }

    private func append(log line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("[\(stamp)] \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// One accepted TCP connection: buffers bytes, decides between HTTP and the
/// subscription protocol, and parses accordingly.
@MainActor
final class BridgeServerConnection {
    private let connection: NWConnection
    private weak var server: BridgeServer?
    private var buffer = Data()
    private var mode: Mode = .undetermined

    private enum Mode {
        case undetermined
        case http
        case subscriber
    }

    init(connection: NWConnection, server: BridgeServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.closed() }
                if case .cancelled = state { self?.closed() }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        connection.cancel()
    }

    private func closed() {
        server?.connectionDidClose(self)
    }

    func send(_ message: BridgeMessage) {
        guard let data = message.encodedLine() else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.process()
                }
                if isComplete || error != nil {
                    self.connection.cancel()
                    self.closed()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func process() {
        if mode == .undetermined {
            let handshake = Data(BridgeMessage.subscribeHandshake.utf8)
            if buffer.count >= handshake.count {
                mode = buffer.starts(with: handshake) ? .subscriber : .http
                if mode == .subscriber {
                    // Drop the handshake line.
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        buffer.removeSubrange(buffer.startIndex...newline)
                    } else {
                        buffer.removeAll()
                    }
                    server?.connectionDidSubscribe(self)
                }
            } else if !buffer.isEmpty && !handshake.starts(with: buffer) {
                mode = .http
            }
        }

        switch mode {
        case .undetermined:
            break
        case .subscriber:
            drainSubscriberLines()
        case .http:
            drainHTTP()
        }
    }

    private func drainSubscriberLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let message = BridgeMessage.decodeLine(line) {
                server?.handleSubscriberMessage(message, from: self)
            }
        }
    }

    private func drainHTTP() {
        guard let request = HTTPRequest.parse(from: buffer) else { return }
        let response = server?.handleHTTPRequest(request)
            ?? HTTPResponse(status: 503, body: "server unavailable")
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.connection.cancel()
                self?.closed()
            }
        })
        buffer.removeAll()
    }
}
#endif
