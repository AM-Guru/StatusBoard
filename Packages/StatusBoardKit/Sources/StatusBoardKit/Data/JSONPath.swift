import Foundation

/// A small dot-path evaluator for pulling values out of fetched JSON.
///
/// Supported syntax (an optional leading `$.` is ignored):
///   `data.items[0].name`   — object keys and array indices
///   `data.items[*].price`  — wildcard fans out over an array
///   `results[-1]`          — negative indices count from the end
public enum JSONPath {
    public enum Segment: Equatable {
        case key(String)
        case index(Int)
        case wildcard
    }

    public static func parse(_ path: String) -> [Segment] {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$.") { trimmed.removeFirst(2) }
        else if trimmed.hasPrefix("$") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return [] }

        var segments: [Segment] = []
        for component in trimmed.split(separator: ".") {
            var text = String(component)
            // Split "items[3][*]" into key + subscripts.
            while let open = text.firstIndex(of: "[") {
                let keyPart = String(text[text.startIndex..<open])
                if !keyPart.isEmpty { segments.append(.key(keyPart)) }
                guard let close = text.firstIndex(of: "]") else { text = ""; break }
                let inner = String(text[text.index(after: open)..<close])
                if inner == "*" {
                    segments.append(.wildcard)
                } else if let index = Int(inner) {
                    segments.append(.index(index))
                }
                text = String(text[text.index(after: close)...])
            }
            if !text.isEmpty { segments.append(.key(text)) }
        }
        return segments
    }

    /// Evaluates a path, returning every match (wildcards produce many).
    public static func evaluate(_ path: String, in root: JSONValue) -> [JSONValue] {
        var current = [root]
        for segment in parse(path) {
            var next: [JSONValue] = []
            for value in current {
                switch segment {
                case .key(let key):
                    if let child = value[key] { next.append(child) }
                case .index(let index):
                    if let array = value.arrayValue {
                        let resolved = index < 0 ? array.count + index : index
                        if array.indices.contains(resolved) { next.append(array[resolved]) }
                    }
                case .wildcard:
                    if let array = value.arrayValue {
                        next.append(contentsOf: array)
                    } else if let object = value.objectValue {
                        next.append(contentsOf: object.keys.sorted().compactMap { object[$0] })
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    public static func first(_ path: String, in root: JSONValue) -> JSONValue? {
        evaluate(path, in: root).first
    }
}
