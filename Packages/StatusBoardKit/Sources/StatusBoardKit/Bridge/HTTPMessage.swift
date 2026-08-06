import Foundation

/// A tiny HTTP/1.1 request parser — just enough for the bridge's JSON API.
public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    /// Returns nil until the buffer holds a complete request (headers + body).
    public static func parse(from buffer: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1]).components(separatedBy: "?").first ?? "/"

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }
        let body = contentLength > 0
            ? buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
            : nil

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

public struct HTTPResponse {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int, contentType: String = "text/plain", body: String) {
        self.status = status
        self.contentType = contentType
        self.body = Data(body.utf8)
    }

    public init(status: Int, contentType: String, bodyData: Data) {
        self.status = status
        self.contentType = contentType
        self.body = bodyData
    }

    public static func json(_ object: JSONValue) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json",
                     bodyData: Data(JSONValue.object(objectify(object)).encodedString().utf8))
    }

    public static func json(_ object: [String: JSONValue]) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json",
                     bodyData: Data(JSONValue.object(object).encodedString().utf8))
    }

    private static func objectify(_ value: JSONValue) -> [String: JSONValue] {
        value.objectValue ?? ["value": value]
    }

    private var statusText: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Status"
        }
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
