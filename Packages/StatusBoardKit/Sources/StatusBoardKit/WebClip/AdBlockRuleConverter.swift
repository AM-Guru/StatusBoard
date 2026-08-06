import Foundation

/// Converts Adblock Plus filter syntax (the format EasyList and friends ship
/// in) into WebKit's content-blocker JSON, which `WKContentRuleListStore`
/// compiles into native rules. This is what lets us block ads inside the
/// nested `WKWebView` without shipping a whole browser engine.
///
/// Supported subset — the parts that carry the overwhelming majority of a list:
///   `||example.com^`        domain-anchored network block
///   `|http://example.com`   start-anchored block
///   `/ads/banner`           substring block
///   `/regex/`               raw regular expression
///   `@@…`                   exception (ignore-previous-rules)
///   `…$script,third-party`  resource-type / third-party options
///   `…$domain=a.com|~b.com` domain scoping
///   `example.com##.ad`      cosmetic element hiding
///   `##.ad`                 global cosmetic element hiding
/// Unsupported constructs (`#?#`, `#$#`, `$csp=`, regex cosmetics …) are
/// skipped rather than guessed at.
public enum AdBlockRuleConverter {

    /// WebKit refuses very large lists and compilation time grows with rule
    /// count, so we cap conversion. EasyList's most valuable rules come first.
    public static let defaultRuleLimit = 30_000

    public struct Rule: Codable, Equatable {
        public struct Trigger: Codable, Equatable {
            public var urlFilter: String
            public var urlFilterIsCaseSensitive: Bool?
            public var ifDomain: [String]?
            public var unlessDomain: [String]?
            public var resourceType: [String]?
            public var loadType: [String]?

            enum CodingKeys: String, CodingKey {
                case urlFilter = "url-filter"
                case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
                case ifDomain = "if-domain"
                case unlessDomain = "unless-domain"
                case resourceType = "resource-type"
                case loadType = "load-type"
            }
        }

        public struct Action: Codable, Equatable {
            public var type: String
            public var selector: String?
        }

        public var trigger: Trigger
        public var action: Action
    }

    /// Converts a whole filter list. Exceptions are emitted after blocks so
    /// WebKit's "ignore-previous-rules" ordering works.
    public static func convert(filterList text: String,
                               limit: Int = defaultRuleLimit) -> [Rule] {
        var blocks: [Rule] = []
        var exceptions: [Rule] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if blocks.count + exceptions.count >= limit { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Comments and metadata.
            if line.hasPrefix("!") || line.hasPrefix("[") { continue }

            guard let rule = convert(line: line) else { continue }
            if rule.action.type == "ignore-previous-rules" {
                exceptions.append(rule)
            } else {
                blocks.append(rule)
            }
        }
        return blocks + exceptions
    }

    /// Converts a single filter line, or nil when it isn't supported.
    public static func convert(line: String) -> Rule? {
        // Cosmetic rules: element hiding.
        if let hashRange = line.range(of: "##") {
            let domainPart = String(line[line.startIndex..<hashRange.lowerBound])
            let selector = String(line[hashRange.upperBound...])
            guard !selector.isEmpty, isPlainCSSSelector(selector) else { return nil }
            var trigger = Rule.Trigger(urlFilter: ".*")
            if !domainPart.isEmpty {
                let domains = splitDomains(domainPart)
                if !domains.included.isEmpty { trigger.ifDomain = domains.included }
                if !domains.excluded.isEmpty { trigger.unlessDomain = domains.excluded }
            }
            return Rule(trigger: trigger,
                        action: Rule.Action(type: "css-display-none", selector: selector))
        }
        // Cosmetic exceptions and extended syntax we don't emulate.
        if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") {
            return nil
        }

        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body.removeFirst(2) }

        // Options after the last unescaped '$'.
        var options: [String] = []
        if let dollar = body.lastIndex(of: "$"), !body.hasPrefix("/") || body.dropFirst().contains("/") {
            let optionText = String(body[body.index(after: dollar)...])
            // A '$' inside a regex body isn't an option list.
            if !optionText.isEmpty, optionText.range(of: "^[a-zA-Z0-9,~=|._\\-*]+$",
                                                     options: .regularExpression) != nil {
                options = optionText.split(separator: ",").map(String.init)
                body = String(body[body.startIndex..<dollar])
            }
        }
        guard !body.isEmpty else { return nil }

        var trigger: Rule.Trigger
        if body.hasPrefix("/") && body.hasSuffix("/") && body.count > 2 {
            // Raw regular expression filter.
            let pattern = String(body.dropFirst().dropLast())
            guard isSafeRegex(pattern) else { return nil }
            trigger = Rule.Trigger(urlFilter: pattern)
        } else {
            guard let pattern = urlFilter(fromPattern: body) else { return nil }
            trigger = Rule.Trigger(urlFilter: pattern)
        }

        var resourceTypes: [String] = []
        var loadTypes: [String] = []
        var unsupported = false

        for option in options {
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            if name.hasPrefix("domain=") {
                let domains = splitDomains(String(name.dropFirst("domain=".count)))
                if !domains.included.isEmpty { trigger.ifDomain = domains.included }
                if !domains.excluded.isEmpty { trigger.unlessDomain = domains.excluded }
                continue
            }
            switch name {
            case "third-party":
                loadTypes.append(negated ? "first-party" : "third-party")
            case "match-case":
                trigger.urlFilterIsCaseSensitive = true
            case "script": resourceTypes.append("script")
            case "image": resourceTypes.append("image")
            case "stylesheet": resourceTypes.append("style-sheet")
            case "subdocument": resourceTypes.append("document")
            case "document": resourceTypes.append("document")
            case "font": resourceTypes.append("font")
            case "media": resourceTypes.append("media")
            case "xmlhttprequest": resourceTypes.append("raw")
            case "websocket": resourceTypes.append("raw")
            case "other", "ping", "beacon": resourceTypes.append("raw")
            case "popup", "elemhide", "generichide", "genericblock",
                 "csp", "webrtc", "object", "object-subrequest", "important":
                // Not expressible in WebKit rules; skipping beats mis-blocking.
                unsupported = true
            default:
                unsupported = true
            }
            if unsupported { break }
        }
        if unsupported { return nil }

        if !resourceTypes.isEmpty { trigger.resourceType = Array(Set(resourceTypes)).sorted() }
        if !loadTypes.isEmpty { trigger.loadType = Array(Set(loadTypes)).sorted() }

        return Rule(trigger: trigger,
                    action: Rule.Action(type: isException ? "ignore-previous-rules" : "block",
                                        selector: nil))
    }

    // MARK: - Pattern translation

    /// Translates an ABP URL pattern into the regular expression WebKit wants.
    static func urlFilter(fromPattern pattern: String) -> String? {
        var source = pattern
        var result = ""

        if source.hasPrefix("||") {
            source.removeFirst(2)
            // Domain anchor: scheme, optional subdomains.
            result += "^[^:]+:(//)?([^/?#]+\\.)?"
        } else if source.hasPrefix("|") {
            source.removeFirst()
            result += "^"
        }

        var trailingAnchor = false
        if source.hasSuffix("|") {
            source.removeLast()
            trailingAnchor = true
        }
        guard !source.isEmpty else { return nil }

        for character in source {
            switch character {
            case "*":
                result += ".*"
            case "^":
                // ABP separator: any non-alphanumeric-ish delimiter or end.
                result += "[/:?=&]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\", "$":
                result += "\\" + String(character)
            default:
                result.append(character)
            }
        }
        if trailingAnchor { result += "$" }

        guard isSafeRegex(result) else { return nil }
        return result
    }

    /// WebKit rejects lists containing patterns it can't compile, which would
    /// fail the *whole* list — so validate each one first.
    static func isSafeRegex(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, pattern.count <= 500 else { return false }
        // WebKit's engine has no lookahead/backreference support.
        if pattern.contains("(?") || pattern.contains("\\1") { return false }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    static func splitDomains(_ text: String) -> (included: [String], excluded: [String]) {
        var included: [String] = []
        var excluded: [String] = []
        for part in text.split(separator: "|") {
            let domain = String(part)
            if domain.hasPrefix("~") {
                let bare = String(domain.dropFirst())
                if !bare.isEmpty { excluded.append("*" + bare) }
            } else if !domain.isEmpty {
                included.append("*" + domain)
            }
        }
        return (included, excluded)
    }

    /// Guards against extended-CSS syntax WebKit's selector engine rejects.
    static func isPlainCSSSelector(_ selector: String) -> Bool {
        let unsupported = [":has(", ":contains(", ":matches-css", ":-abp-",
                           ":xpath(", ":style(", ":upward(", ":nth-ancestor("]
        for token in unsupported where selector.contains(token) { return false }
        return true
    }

    /// JSON encoding of converted rules, ready for `WKContentRuleListStore`.
    public static func json(for rules: [Rule]) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
