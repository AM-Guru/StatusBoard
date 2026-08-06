import Foundation

/// A minimal Model Context Protocol client: initialize, list tools, call tools.
/// Supports stdio servers (macOS only) and streamable-HTTP servers (all platforms).
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    private let config: MCPServerConfig
    private var transport: MCPTransport?
    private var nextID = 1

    public init(config: MCPServerConfig) {
        self.config = config
    }

    deinit {
        transport?.shutdown()
    }

    // MARK: - Public API

    public func callTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        try await ensureInitialized()
        let result = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
        return result
    }

    public func listTools() async throws -> [String] {
        try await ensureInitialized()
        let result = try await request(method: "tools/list", params: .object([:]))
        guard let tools = result["tools"]?.arrayValue else { return [] }
        return tools.compactMap { $0["name"]?.stringValue }
    }

    /// Flattens a tools/call result into displayable text.
    public static func text(fromToolResult result: JSONValue) -> String {
        if let content = result["content"]?.arrayValue {
            let parts = content.compactMap { item -> String? in
                if item["type"]?.stringValue == "text" { return item["text"]?.stringValue }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let structured = result["structuredContent"] {
            return structured.encodedString(pretty: true)
        }
        return result.encodedString(pretty: true)
    }

    public func shutdown() {
        transport?.shutdown()
        transport = nil
    }

    // MARK: - Lifecycle

    private func ensureInitialized() async throws {
        guard transport == nil else { return }
        let transport: MCPTransport
        switch config.transport {
        case .stdio:
            #if os(macOS)
            guard let command = config.command, !command.isEmpty else {
                throw SBError.message("No command configured for stdio MCP server")
            }
            transport = try MCPStdioTransport(command: command, arguments: config.arguments)
            #else
            throw SBError.message("stdio MCP servers require the Mac app (use an HTTP server or the bridge)")
            #endif
        case .http:
            guard let urlString = config.url, let url = URL(string: urlString) else {
                throw SBError.message("No URL configured for HTTP MCP server")
            }
            transport = MCPHTTPTransport(url: url, headers: config.headers)
        }
        self.transport = transport

        let initResult = try await request(method: "initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("StatusBoard"),
                "version": .string("1.0"),
            ]),
        ]))
        _ = initResult
        try await transport.sendNotification(method: "notifications/initialized", params: .object([:]))
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard let transport else { throw SBError.message("MCP transport not ready") }
        let id = nextID
        nextID += 1
        let payload = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let response = try await transport.sendRequest(payload, id: id)
        if let error = response["error"] {
            let message = error["message"]?.stringValue ?? error.encodedString()
            throw SBError.message("MCP error: \(message)")
        }
        return response["result"] ?? .null
    }
}

/// Panel-facing entry point: run one tool call and shape it into a snapshot.
public enum MCPSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let config = settings.mcp else {
            return .error("Configure an MCP server in the panel settings")
        }
        let arguments: JSONValue
        if let json = config.argumentsJSON, !json.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = try? JSONValue.parse(json) else {
                return .error("Tool arguments are not valid JSON")
            }
            arguments = parsed
        } else {
            arguments = .object([:])
        }

        let client = MCPClient(config: config.server)
        defer { Task { await client.shutdown() } }
        do {
            let result = try await client.callTool(name: config.tool, arguments: arguments)
            if result["isError"]?.doubleValue == 1 {
                return .error(MCPClient.text(fromToolResult: result))
            }
            let text = MCPClient.text(fromToolResult: result)
            if let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .number(number, unit: settings.unit)
            }
            return .text(text)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
