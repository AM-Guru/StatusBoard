import Foundation

/// Fetches JSON (or CSV) from the web and extracts values/series/tables
/// using the panel's configured paths.
public enum WebQuerySource {
    public static func fetch(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("StatusBoard/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SBError.http(http.statusCode)
        }
        return data
    }

    /// A single numeric or textual value for value-style panels.
    public static func value(settings: PanelSettings) async -> DataSnapshot {
        guard let urlString = settings.url, let url = URL(string: urlString) else {
            return .error("No URL configured")
        }
        do {
            let data = try await fetch(url: url)
            let json = try JSONValue.parse(data)
            let target = settings.valuePath.flatMap { JSONPath.first($0, in: json) } ?? json
            if let number = target.doubleValue {
                return .number(number, unit: settings.unit)
            }
            if let text = target.stringValue {
                return .text(text)
            }
            return .text(target.encodedString(pretty: true))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// A series for graph panels.
    public static func series(settings: PanelSettings) async -> DataSnapshot {
        guard let urlString = settings.url, let url = URL(string: urlString) else {
            return .error("No URL configured")
        }
        do {
            let data = try await fetch(url: url)
            let json = try JSONValue.parse(data)
            let elements: [JSONValue]
            if let path = settings.seriesPath, !path.isEmpty {
                let matches = JSONPath.evaluate(path, in: json)
                // A path may resolve to one array or fan out to many scalars.
                if matches.count == 1, let array = matches[0].arrayValue {
                    elements = array
                } else {
                    elements = matches
                }
            } else if let array = json.arrayValue {
                elements = array
            } else {
                return .error("Series path did not match an array")
            }

            var points: [SeriesPoint] = []
            for (offset, element) in elements.enumerated() {
                let value: Double?
                if let valuePath = settings.pointValuePath, !valuePath.isEmpty {
                    value = JSONPath.first(valuePath, in: element)?.doubleValue
                } else {
                    value = element.doubleValue
                }
                guard let value else { continue }
                var label: String?
                if let labelPath = settings.pointLabelPath, !labelPath.isEmpty {
                    label = JSONPath.first(labelPath, in: element)?.stringValue
                }
                points.append(SeriesPoint(label: label ?? String(offset), value: value))
            }
            guard !points.isEmpty else { return .error("No numeric points found") }
            return .series(SeriesData(points: points, unit: settings.unit))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// A table from a JSON array of objects, or CSV when the URL ends in .csv.
    public static func table(settings: PanelSettings) async -> DataSnapshot {
        guard let urlString = settings.url, let url = URL(string: urlString) else {
            return .error("No URL configured")
        }
        do {
            let data = try await fetch(url: url)
            if url.pathExtension.lowercased() == "csv"
                || settings.valuePath == nil && (try? JSONValue.parse(data)) == nil {
                let text = String(decoding: data, as: UTF8.self)
                return .table(csv(text))
            }
            let json = try JSONValue.parse(data)
            let rowsSource: [JSONValue]
            if let path = settings.seriesPath, !path.isEmpty {
                let matches = JSONPath.evaluate(path, in: json)
                rowsSource = matches.count == 1 ? (matches[0].arrayValue ?? matches) : matches
            } else {
                rowsSource = json.arrayValue ?? []
            }
            guard !rowsSource.isEmpty else { return .error("No rows found") }

            var columns: [String] = []
            for element in rowsSource.prefix(20) {
                for key in element.objectValue?.keys.sorted() ?? [] where !columns.contains(key) {
                    columns.append(key)
                }
            }
            if columns.isEmpty {
                return .table(TableData(columns: ["Value"],
                                        rows: rowsSource.map { [$0.stringValue ?? $0.encodedString()] }))
            }
            let rows = rowsSource.map { element in
                columns.map { element[$0]?.stringValue ?? "" }
            }
            return .table(TableData(columns: columns, rows: rows))
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func csv(_ text: String) -> TableData {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { return TableData(columns: [], rows: []) }
        let columns = splitCSVLine(header)
        let rows = lines.dropFirst().map { splitCSVLine($0) }
        return TableData(columns: columns, rows: rows)
    }

    static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            switch char {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public enum SBError: LocalizedError {
    case http(Int)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .message(let text): return text
        }
    }
}
