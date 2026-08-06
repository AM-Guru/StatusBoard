import Foundation
import CryptoKit

// MARK: - GitHub

/// GitHub REST connector: workflow runs, issues, PRs, releases, stars.
/// A token is optional for public repos.
public enum GitHubSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let config = settings.connector,
              let repo = config.repo, repo.contains("/") else {
            return .error("Set a repository like owner/name in the panel settings")
        }
        do {
            switch config.mode {
            case "issues", "prs":
                let kind = config.mode == "issues" ? "issues" : "pulls"
                let json = try await request("repos/\(repo)/\(kind)?state=open&per_page=20",
                                             token: config.token)
                let items = (json.arrayValue ?? []).compactMap { item -> FeedItem? in
                    guard let title = item["title"]?.stringValue else { return nil }
                    let number = item["number"]?.doubleValue.map { "#\(Int($0)) " } ?? ""
                    var published: Date?
                    if let updated = item["updated_at"]?.stringValue {
                        published = try? Date(updated, strategy: .iso8601)
                    }
                    return FeedItem(title: number + title,
                                    link: item["html_url"]?.stringValue,
                                    published: published)
                }
                return items.isEmpty
                    ? .text("No open \(config.mode)")
                    : .feed(items)

            case "releases":
                let json = try await request("repos/\(repo)/releases/latest", token: config.token)
                let name = json["name"]?.stringValue ?? json["tag_name"]?.stringValue ?? "—"
                return .text("Latest release\n\(name)")

            case "stars":
                let json = try await request("repos/\(repo)", token: config.token)
                guard let stars = json["stargazers_count"]?.doubleValue else {
                    return .error("Unexpected response")
                }
                return .number(stars, unit: "stars")

            default: // "runs"
                let json = try await request("repos/\(repo)/actions/runs?per_page=12",
                                             token: config.token)
                guard let runs = json["workflow_runs"]?.arrayValue else {
                    return .error("No workflow runs found")
                }
                let rows = runs.map { run -> [String] in
                    let name = run["name"]?.stringValue ?? "workflow"
                    let status = normalizedRunStatus(
                        conclusion: run["conclusion"]?.stringValue,
                        status: run["status"]?.stringValue)
                    let branch = run["head_branch"]?.stringValue ?? "—"
                    var when = "—"
                    if let created = run["created_at"]?.stringValue,
                       let date = try? Date(created, strategy: .iso8601) {
                        when = date.formatted(.relative(presentation: .named))
                    }
                    return [name, status, branch, when]
                }
                return .table(TableData(columns: ["Workflow", "Status", "Branch", "When"],
                                        rows: rows))
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Maps GitHub run states onto the table renderer's status vocabulary.
    static func normalizedRunStatus(conclusion: String?, status: String?) -> String {
        if let conclusion {
            switch conclusion {
            case "success": return "success"
            case "failure", "timed_out", "startup_failure": return "failed"
            case "cancelled", "skipped", "neutral": return "warning"
            case "action_required": return "pending"
            default: return conclusion
            }
        }
        switch status {
        case "in_progress": return "running"
        case "queued", "waiting", "requested", "pending": return "pending"
        default: return status ?? "unknown"
        }
    }

    static func request(_ path: String, token: String?) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("StatusBoard/1.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SBError.message("GitHub HTTP \(http.statusCode)")
        }
        return try JSONValue.parse(data)
    }
}

// MARK: - App Store Connect

/// App Store Connect API connector. Signs requests with an ES256 JWT built
/// from your API key (.p8), key id, and issuer id.
public enum AppStoreConnectSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let config = settings.connector,
              let keyID = config.keyID, !keyID.isEmpty,
              let issuerID = config.issuerID, !issuerID.isEmpty,
              let pem = config.privateKeyPEM, !pem.isEmpty else {
            return .error("Enter your App Store Connect key ID, issuer ID, and .p8 key")
        }
        do {
            let token = try jwt(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem)
            switch config.mode {
            case "builds":
                let json = try await request("builds?limit=10&sort=-uploadedDate&include=preReleaseVersion",
                                             token: token)
                let rows = (json["data"]?.arrayValue ?? []).map { build -> [String] in
                    let attributes = build["attributes"]
                    let version = attributes?["version"]?.stringValue ?? "—"
                    let state = friendlyBuildState(attributes?["processingState"]?.stringValue)
                    var when = "—"
                    if let uploaded = attributes?["uploadedDate"]?.stringValue,
                       let date = try? Date(uploaded, strategy: .iso8601) {
                        when = date.formatted(.relative(presentation: .named))
                    }
                    let expired = attributes?["expired"]?.doubleValue == 1 ? "expired" : "active"
                    return [version, state, expired, when]
                }
                return rows.isEmpty
                    ? .text("No builds")
                    : .table(TableData(columns: ["Build", "State", "Status", "Uploaded"], rows: rows))

            case "reviews":
                guard let appID = config.query, !appID.isEmpty else {
                    return .error("Enter your numeric app ID for reviews")
                }
                let json = try await request("apps/\(appID)/customerReviews?limit=10&sort=-createdDate",
                                             token: token)
                let items = (json["data"]?.arrayValue ?? []).compactMap { review -> FeedItem? in
                    let attributes = review["attributes"]
                    guard let rating = attributes?["rating"]?.doubleValue else { return nil }
                    let stars = String(repeating: "★", count: Int(rating))
                        + String(repeating: "☆", count: 5 - Int(rating))
                    let title = attributes?["title"]?.stringValue ?? ""
                    var published: Date?
                    if let created = attributes?["createdDate"]?.stringValue {
                        published = try? Date(created, strategy: .iso8601)
                    }
                    return FeedItem(title: "\(stars)  \(title)", published: published)
                }
                return items.isEmpty ? .text("No reviews yet") : .feed(items)

            default: // "apps"
                let json = try await request("apps?limit=20", token: token)
                let rows = (json["data"]?.arrayValue ?? []).map { app -> [String] in
                    let attributes = app["attributes"]
                    return [attributes?["name"]?.stringValue ?? "—",
                            attributes?["bundleId"]?.stringValue ?? "—",
                            attributes?["sku"]?.stringValue ?? "—"]
                }
                return rows.isEmpty
                    ? .text("No apps")
                    : .table(TableData(columns: ["App", "Bundle ID", "SKU"], rows: rows))
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func friendlyBuildState(_ raw: String?) -> String {
        switch raw {
        case "VALID": return "success"
        case "PROCESSING": return "building"
        case "FAILED", "INVALID": return "failed"
        default: return raw?.lowercased() ?? "—"
        }
    }

    /// ES256 JWT per Apple's App Store Connect API spec.
    static func jwt(keyID: String, issuerID: String, privateKeyPEM: String,
                    now: Date = Date()) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
        let issued = Int(now.timeIntervalSince1970)
        let payload = #"{"iss":"\#(issuerID)","iat":\#(issued),"exp":\#(issued + 1200),"aud":"appstoreconnect-v1"}"#
        let signingInput = base64URL(Data(header.utf8)) + "." + base64URL(Data(payload.utf8))
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw SBError.message("Could not read the .p8 private key — paste its full PEM contents")
        }
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func request(_ path: String, token: String) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SBError.message("App Store Connect HTTP \(http.statusCode)")
        }
        return try JSONValue.parse(data)
    }
}

// MARK: - Supabase

/// Supabase connector: PostgREST table reads with the project URL + API key,
/// or arbitrary SQL through the management API with a personal access token.
public enum SupabaseSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let config = settings.connector else {
            return .error("Configure the Supabase connection in the panel settings")
        }
        do {
            let rows: JSONValue
            if config.mode == "sql" {
                guard let ref = config.projectURL?.trimmingCharacters(in: .whitespaces), !ref.isEmpty,
                      let token = config.token, !token.isEmpty,
                      let sql = config.query, !sql.isEmpty else {
                    return .error("SQL mode needs the project ref, an access token, and a query")
                }
                var request = URLRequest(
                    url: URL(string: "https://api.supabase.com/v1/projects/\(ref)/database/query")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(JSONValue.object(["query": .string(sql)]).encodedString().utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw SBError.message("Supabase HTTP \(http.statusCode)")
                }
                rows = try JSONValue.parse(data)
            } else {
                guard var base = config.projectURL?.trimmingCharacters(in: .whitespaces), !base.isEmpty,
                      let key = config.token, !key.isEmpty,
                      let path = config.query, !path.isEmpty else {
                    return .error("Enter the project URL, an API key, and a table query like todos?select=*")
                }
                if !base.contains("://") { base = "https://" + base }
                var request = URLRequest(url: URL(string: "\(base)/rest/v1/\(path)")!)
                request.timeoutInterval = 30
                request.setValue(key, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw SBError.message("Supabase HTTP \(http.statusCode)")
                }
                rows = try JSONValue.parse(data)
            }
            return snapshot(fromRows: rows, settings: settings)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Shapes a JSON row array into the panel's preferred snapshot: a single
    /// value, a labeled series, or a table.
    static func snapshot(fromRows rows: JSONValue, settings: PanelSettings) -> DataSnapshot {
        let elements = rows.arrayValue ?? [rows]
        guard !elements.isEmpty else { return .text("0 rows") }

        // Single row & column → big number/text.
        if elements.count == 1, let object = elements[0].objectValue, object.count == 1,
           let only = object.values.first {
            if let number = only.doubleValue { return .number(number, unit: settings.unit) }
            return .text(only.stringValue ?? only.encodedString())
        }

        // Two columns where the second is numeric → labeled series.
        if let first = elements.first?.objectValue, first.count == 2 {
            let keys = first.keys.sorted()
            let labelKey = keys[0], valueKey = keys[1]
            let points = elements.compactMap { element -> SeriesPoint? in
                guard let value = element[valueKey]?.doubleValue else { return nil }
                return SeriesPoint(label: element[labelKey]?.stringValue, value: value)
            }
            if points.count == elements.count {
                return .series(SeriesData(points: points, unit: settings.unit))
            }
        }

        // Otherwise a table.
        var columns: [String] = []
        for element in elements.prefix(20) {
            for key in element.objectValue?.keys.sorted() ?? [] where !columns.contains(key) {
                columns.append(key)
            }
        }
        let tableRows = elements.prefix(50).map { element in
            columns.map { element[$0]?.stringValue ?? "" }
        }
        return .table(TableData(columns: columns, rows: Array(tableRows)))
    }
}

// MARK: - Web log analytics

/// Fetches an access log (Apache/nginx combined format) and summarizes it:
/// hourly traffic, top paths, or status-class mix.
public enum LogAnalyticsSource {
    public struct Entry {
        public var date: Date?
        public var path: String
        public var status: Int
    }

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let config = settings.connector,
              let urlString = config.query, let url = URL(string: urlString) else {
            return .error("Set the URL of an access log in the panel settings")
        }
        do {
            let data = try await WebQuerySource.fetch(url: url)
            let text = String(decoding: data.suffix(4_000_000), as: UTF8.self)
            let entries = parse(text)
            guard !entries.isEmpty else { return .error("No log lines matched the combined format") }

            switch config.mode {
            case "paths":
                var counts: [String: Int] = [:]
                for entry in entries { counts[entry.path, default: 0] += 1 }
                let top = counts.sorted { $0.value > $1.value }.prefix(12)
                return .table(TableData(
                    columns: ["Path", "Requests"],
                    rows: top.map { [$0.key, String($0.value)] }))

            case "status":
                var classes: [Int: Int] = [:]
                for entry in entries { classes[entry.status / 100, default: 0] += 1 }
                let total = max(1, entries.count)
                let statuses = classes.sorted { $0.key < $1.key }.map { klass, count in
                    ServiceStatus(
                        id: "\(klass)xx", name: "\(klass)xx · \(count) (\(count * 100 / total)%)",
                        state: klass <= 3 ? .up : (klass == 4 ? .degraded : .down))
                }
                return .statuses(statuses)

            default: // "traffic"
                let calendar = Calendar.current
                var buckets: [Date: Int] = [:]
                for entry in entries {
                    guard let date = entry.date else { continue }
                    let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
                    buckets[hour, default: 0] += 1
                }
                let sorted = buckets.sorted { $0.key < $1.key }.suffix(48)
                guard !sorted.isEmpty else { return .number(Double(entries.count), unit: "req") }
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                let points = sorted.map { date, count in
                    SeriesPoint(label: formatter.string(from: date), date: date,
                                value: Double(count))
                }
                return .series(SeriesData(points: points, unit: "req/h"))
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static let lineRegex = try! NSRegularExpression(
        pattern: #"^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3})"#)

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MMM/yyyy:HH:mm:ss Z"
        return formatter
    }()

    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(1024)
        for line in text.split(whereSeparator: \.isNewline).suffix(20_000) {
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            guard let match = lineRegex.firstMatch(in: string, range: range),
                  let dateRange = Range(match.range(at: 2), in: string),
                  let pathRange = Range(match.range(at: 4), in: string),
                  let statusRange = Range(match.range(at: 5), in: string),
                  let status = Int(string[statusRange]) else { continue }
            let path = String(string[pathRange]).components(separatedBy: "?").first ?? "/"
            entries.append(Entry(date: dateFormatter.date(from: String(string[dateRange])),
                                 path: path, status: status))
        }
        return entries
    }
}
