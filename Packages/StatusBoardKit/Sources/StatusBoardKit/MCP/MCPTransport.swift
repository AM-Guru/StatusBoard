import Foundation

protocol MCPTransport {
    func sendRequest(_ payload: JSONValue, id: Int) async throws -> JSONValue
    func sendNotification(method: String, params: JSONValue) async throws
    func shutdown()
}

// MARK: - Streamable HTTP

/// Speaks MCP's streamable-HTTP transport: POST each JSON-RPC message; the
/// response is either a JSON body or a short SSE stream containing it.
final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private var sessionID: String?
    private let lock = NSLock()

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    private func currentSessionID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return sessionID
    }

    private func storeSessionID(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        sessionID = value
    }

    func sendRequest(_ payload: JSONValue, id: Int) async throws -> JSONValue {
        let (data, response) = try await post(payload)
        if let http = response as? HTTPURLResponse {
            if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
                storeSessionID(session)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SBError.http(http.statusCode)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/event-stream") {
                return try Self.firstJSONRPCMessage(inSSE: data, matching: id)
            }
        }
        return try JSONValue.parse(data)
    }

    func sendNotification(method: String, params: JSONValue) async throws {
        let payload = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        _ = try? await post(payload)
    }

    func shutdown() {}

    private func post(_ payload: JSONValue) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID = currentSessionID() {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(payload.encodedString().utf8)
        return try await URLSession.shared.data(for: request)
    }

    /// Pulls JSON-RPC messages out of an SSE body and returns the response
    /// whose id matches.
    static func firstJSONRPCMessage(inSSE data: Data, matching id: Int) throws -> JSONValue {
        let text = String(decoding: data, as: UTF8.self)
        var lastMessage: JSONValue?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let message = try? JSONValue.parse(body) else { continue }
            lastMessage = message
            if Int(message["id"]?.doubleValue ?? -1) == id {
                return message
            }
        }
        if let lastMessage { return lastMessage }
        throw SBError.message("No JSON-RPC response in SSE stream")
    }
}

// MARK: - stdio (macOS only)

#if os(macOS)
/// Spawns the server process and exchanges newline-delimited JSON-RPC over
/// stdin/stdout.
final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    init(command: String, arguments: [String]) throws {
        process = Process()
        // Resolve through /usr/bin/env so bare names like "npx" work.
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        try process.run()
    }

    func sendRequest(_ payload: JSONValue, id: Int) async throws -> JSONValue {
        try write(payload)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            // Timeout guard.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let continuation = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                continuation?.resume(throwing: SBError.message("MCP request timed out"))
            }
        }
    }

    func sendNotification(method: String, params: JSONValue) async throws {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume(throwing: SBError.message("MCP server shut down"))
        }
    }

    private func write(_ payload: JSONValue) throws {
        guard process.isRunning else { throw SBError.message("MCP server is not running") }
        var data = Data(payload.encodedString().utf8)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let message = try? JSONValue.parse(line),
                  let idValue = message["id"]?.doubleValue else { continue }
            let id = Int(idValue)
            lock.lock()
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(returning: message)
        }
    }
}
#endif
