import Foundation

/// Instructure Canvas (LMS) connector.
///
/// Authenticates with a personal access token — Canvas → Account → Settings →
/// "+ New Access Token". The host is your institution's Canvas URL, e.g.
/// `https://school.instructure.com`.
///
/// The planner API (`/api/v1/planner/items`) is the workhorse: one call returns
/// assignments, quizzes, and calendar events for a date range, each with its
/// submission state, so "due today", "what's on today", and "am I late" all
/// come from the same shape of data.
public enum CanvasSource {

    public enum Mode: String, CaseIterable, Sendable {
        case dueToday
        case late
        case upcoming
        case grades
        case todaySchedule

        public var displayName: String {
            switch self {
            case .dueToday: return "Due Today"
            case .late: return "Late / Missing"
            case .upcoming: return "Upcoming (7 days)"
            case .grades: return "Current Grades"
            case .todaySchedule: return "Today's Classes"
            }
        }
    }

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let config = settings.connector,
              var host = config.projectURL?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              let token = config.token, !token.isEmpty else {
            return .error("Enter your Canvas URL and access token in the panel settings")
        }
        if !host.contains("://") { host = "https://" + host }
        if host.hasSuffix("/") { host.removeLast() }

        let mode = Mode(rawValue: config.mode) ?? .dueToday
        do {
            switch mode {
            case .grades:
                return try await grades(host: host, token: token)
            case .late:
                return try await missing(host: host, token: token)
            case .dueToday:
                return try await planner(host: host, token: token, days: 0, assignmentsOnly: true)
            case .upcoming:
                return try await planner(host: host, token: token, days: 7, assignmentsOnly: true)
            case .todaySchedule:
                return try await todaySchedule(host: host, token: token)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Queries

    /// Current score per active course.
    static func grades(host: String, token: String) async throws -> DataSnapshot {
        let json = try await request(
            host: host, token: token,
            path: "/api/v1/courses?enrollment_state=active&include[]=total_scores&per_page=50")
        let courses = json.arrayValue ?? []
        var rows: [[String]] = []
        for course in courses {
            guard let name = course["name"]?.stringValue else { continue }
            // Student enrollments carry the computed score.
            let enrollment = (course["enrollments"]?.arrayValue ?? []).first {
                $0["type"]?.stringValue == "student" || $0["computed_current_score"] != nil
            }
            let score = enrollment?["computed_current_score"]?.doubleValue
            // Canvas exposes both; the dedicated letter field is the accurate one.
            let letter = enrollment?["computed_current_letter_grade"]?.stringValue
                ?? enrollment?["computed_current_grade"]?.stringValue
            let scoreText = score.map { formatted($0) + "%" } ?? "—"
            rows.append([shortCourseName(name), scoreText, letter ?? ""])
        }
        guard !rows.isEmpty else { return .text("No active courses") }
        rows.sort { ($0.first ?? "") < ($1.first ?? "") }
        return .table(TableData(columns: ["Course", "Score", "Grade"], rows: rows))
    }

    /// Late or missing work.
    ///
    /// Canvas's own `missing_submissions` endpoint is empty at some
    /// institutions (verified on K12/Stride), so when it returns nothing we
    /// derive the answer from planner submission flags over the past weeks —
    /// which is where the truth actually lives.
    static func missing(host: String, token: String) async throws -> DataSnapshot {
        let json = try await request(
            host: host, token: token,
            path: "/api/v1/users/self/missing_submissions?per_page=50")
        var rows: [[String]] = []
        for item in json.arrayValue ?? [] {
            let name = item["name"]?.stringValue ?? "Assignment"
            let due = item["due_at"]?.stringValue.flatMap { try? Date($0, strategy: .iso8601) }
            let points = item["points_possible"]?.doubleValue.map { formatted($0) } ?? "—"
            rows.append([name, due.map(relativeDay) ?? "—", points])
        }
        if rows.isEmpty {
            rows = try await lateFromPlanner(host: host, token: token)
        }
        guard !rows.isEmpty else { return .text("Nothing late or missing 🎉") }
        return .table(TableData(columns: ["Late / Missing", "Was Due", "Course"], rows: rows))
    }

    /// Past-due planner items Canvas has flagged late or missing.
    static func lateFromPlanner(host: String, token: String,
                                lookbackDays: Int = 45) async throws -> [[String]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let json = try await request(
            host: host, token: token,
            path: "/api/v1/planner/items?start_date=\(iso(start))&end_date=\(iso(today))&per_page=100")

        var rows: [(Date, [String])] = []
        for entry in json.arrayValue ?? [] {
            let submissions = entry["submissions"]
            let missing = submissions?["missing"]?.doubleValue == 1
            let late = submissions?["late"]?.doubleValue == 1
            let submitted = submissions?["submitted"]?.doubleValue == 1
            guard missing || (late && !submitted) else { continue }
            guard let plannable = entry["plannable"] else { continue }
            let title = plannable["title"]?.stringValue ?? "Assignment"
            let due = plannable["due_at"]?.stringValue
                ?? entry["plannable_date"]?.stringValue
            let dueDate = due.flatMap { try? Date($0, strategy: .iso8601) } ?? today
            let course = entry["context_name"]?.stringValue.map(shortCourseName) ?? ""
            rows.append((dueDate, [title, relativeDay(dueDate), course]))
        }
        rows.sort { $0.0 > $1.0 }
        return rows.map(\.1)
    }

    /// Planner items in a date window — the "what do I owe" view.
    static func planner(host: String, token: String, days: Int,
                        assignmentsOnly: Bool) async throws -> DataSnapshot {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: days + 1, to: start) ?? start
        let json = try await request(
            host: host, token: token,
            path: "/api/v1/planner/items?start_date=\(iso(start))&end_date=\(iso(end))&per_page=100")

        var items: [FeedItem] = []
        for entry in json.arrayValue ?? [] {
            let type = entry["plannable_type"]?.stringValue ?? ""
            if assignmentsOnly && !["assignment", "quiz", "discussion_topic",
                                    "sub_assignment", "wiki_page"].contains(type) {
                continue
            }
            // Already handed in? Then it isn't outstanding.
            if entry["submissions"]?["submitted"]?.doubleValue == 1 { continue }
            guard let plannable = entry["plannable"] else { continue }
            let title = plannable["title"]?.stringValue
                ?? plannable["name"]?.stringValue ?? "Untitled"
            let course = entry["context_name"]?.stringValue
            // plannable.due_at is the actual deadline; plannable_date is the
            // bucket Canvas filed it under.
            let dateText = plannable["due_at"]?.stringValue
                ?? entry["plannable_date"]?.stringValue
            let date = dateText.flatMap { try? Date($0, strategy: .iso8601) }
            let late = entry["submissions"]?["missing"]?.doubleValue == 1
            var label = title
            if let course { label = "\(shortCourseName(course)) · \(title)" }
            if late { label = "⚠︎ " + label }
            items.append(FeedItem(title: label, link: entry["html_url"]?.stringValue,
                                  published: date))
        }
        guard !items.isEmpty else {
            return .text(days == 0 ? "Nothing due today 🎉" : "Nothing due in the next \(days) days")
        }
        items.sort { ($0.published ?? .distantFuture) < ($1.published ?? .distantFuture) }
        return .feed(items)
    }

    /// Today's scheduled class meetings, with a clear "day off" answer.
    static func todaySchedule(host: String, token: String) async throws -> DataSnapshot {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let json = try await request(
            host: host, token: token,
            path: "/api/v1/planner/items?start_date=\(iso(start))&end_date=\(iso(end))&per_page=100")

        var rows: [(Date, [String])] = []
        for entry in json.arrayValue ?? [] {
            guard entry["plannable_type"]?.stringValue == "calendar_event",
                  let plannable = entry["plannable"] else { continue }
            let title = plannable["title"]?.stringValue ?? "Class"
            let startText = plannable["start_at"]?.stringValue
                ?? entry["plannable_date"]?.stringValue
            guard let startDate = startText.flatMap({ try? Date($0, strategy: .iso8601) }) else { continue }
            let endDate = plannable["end_at"]?.stringValue
                .flatMap { try? Date($0, strategy: .iso8601) }
            let time = endDate.map { "\(clock(startDate))–\(clock($0))" } ?? clock(startDate)
            let course = entry["context_name"]?.stringValue.map(shortCourseName) ?? ""
            let location = plannable["location_name"]?.stringValue ?? ""
            rows.append((startDate, [time, course.isEmpty ? title : course, location]))
        }
        guard !rows.isEmpty else {
            // Some institutions (K12/Stride among them) keep meeting times in
            // their own portal, not Canvas — don't claim a day off when we
            // simply have nowhere to look.
            let anyEvents = try await request(
                host: host, token: token,
                path: "/api/v1/calendar_events?type=event&all_events=true&per_page=1")
            if (anyEvents.arrayValue ?? []).isEmpty {
                return .error("This Canvas has no class calendar. Use a K12 Class Schedule panel for meeting times.")
            }
            return .text("No classes today — day off 🎉")
        }
        rows.sort { $0.0 < $1.0 }
        return .table(TableData(columns: ["Time", "Class", "Where"],
                                rows: rows.map(\.1)))
    }

    // MARK: - Networking

    static func request(host: String, token: String, path: String) async throws -> JSONValue {
        guard let url = URL(string: host + path) else {
            throw SBError.message("Invalid Canvas URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json+canvas-string-ids", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 {
                throw SBError.message("Canvas rejected the token — create a new access token in Canvas → Account → Settings")
            }
            throw SBError.message("Canvas HTTP \(http.statusCode)")
        }
        return try JSONValue.parse(data)
    }

    // MARK: - Formatting

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    static func relativeDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Canvas course names are often "BIOL 101 — Introduction to Biology
    /// (Fall 2026)". Panels are small, so keep the useful part.
    static func shortCourseName(_ name: String) -> String {
        var text = name
        if let parenthesis = text.firstIndex(of: "(") {
            text = String(text[text.startIndex..<parenthesis])
        }
        for separator in [" — ", " - ", ": "] {
            if let range = text.range(of: separator) {
                text = String(text[text.startIndex..<range.lowerBound])
                break
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
