import Foundation

/// K12 / Stride **OLS** ("Launch Pad") connector — the source of class meeting
/// times, which do not exist in the school's Canvas at all.
///
/// Every call here is a native `URLSession` request through `K12Session`; the
/// portal's web view is used only once, to sign in. `/api/canvas/events/classes`
/// needs no parameters — the server resolves the student from the session — so
/// today's schedule is a single lightweight request.
public enum K12OLSSource {

    public enum Mode: String, CaseIterable, Sendable {
        case todayClasses
        case nextClass
        case weekClasses
        case courses

        public var displayName: String {
            switch self {
            case .todayClasses: return "Today's Classes"
            case .nextClass: return "Next Class"
            case .weekClasses: return "This Week's Classes"
            case .courses: return "Courses & Teachers"
            }
        }
    }

    /// One scheduled meeting as OLS reports it.
    struct ClassEvent {
        var title: String
        var courseName: String
        var teacher: String
        var start: Date?
        var end: Date?
        var timeText: String
        var localDay: String
        var attendance: String   // required | optional | do-not-display
        var platform: String
        var url: String?

        var displayName: String { courseName.isEmpty ? title : courseName }
        var isRequired: Bool { attendance == "required" }
        var isHidden: Bool { attendance == "do-not-display" }
    }

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        let config = settings.connector ?? ConnectorConfig()
        let portal = config.projectURL?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? config.projectURL! : K12Session.defaultPortal
        let mode = Mode(rawValue: config.mode) ?? .todayClasses

        do {
            switch mode {
            case .todayClasses:
                return todaySnapshot(try await todayClasses(portal: portal))
            case .nextClass:
                return nextSnapshot(try await todayClasses(portal: portal))
            case .weekClasses:
                return weekSnapshot(try await weekClasses(portal: portal))
            case .courses:
                return try await coursesSnapshot(portal: portal)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Requests

    /// Today's meetings. Parameter-free: the portal derives the student from
    /// the session cookie.
    static func todayClasses(portal: String) async throws -> [ClassEvent] {
        let json = try await K12Session.shared.json(path: "/api/canvas/events/classes",
                                                    portal: portal)
        return (json["events"]?.arrayValue ?? []).map(parse)
    }

    /// The wider calendar, which needs the student id and course ids.
    static func weekClasses(portal: String) async throws -> [ClassEvent] {
        let identity = try await identity(portal: portal)
        let courses = identity.courseIDs.joined(separator: ",")
        let json = try await K12Session.shared.json(
            path: "/api/canvas/events?userId=\(identity.userID)&courseIds=\(courses)",
            portal: portal)
        return (json["events"]?.arrayValue ?? []).map(parse)
    }

    struct Identity {
        var userID: String
        var courseIDs: [String]
    }

    /// The student id and their courses. `/api/canvas/events/classes` carries
    /// the id for free, which avoids scraping the portal's HTML.
    static func identity(portal: String) async throws -> Identity {
        let classes = try await K12Session.shared.json(path: "/api/canvas/events/classes",
                                                        portal: portal)
        var userID = classes["userId"]?.stringValue
        // Fall back to the id embedded in a class URL when the payload omits it.
        if userID == nil, let first = classes["events"]?.arrayValue?.first,
           let url = first["url"]?.stringValue,
           let match = url.range(of: #"(?<=userId=)\d{4,}"#, options: .regularExpression) {
            userID = String(url[match])
        }
        guard let userID else {
            throw SBError.message("Could not determine your student id from the portal")
        }
        let coursesJSON = try await K12Session.shared.json(path: "/api/courses/\(userID)",
                                                           portal: portal)
        let list = coursesJSON["data"]?.arrayValue ?? coursesJSON["courses"]?.arrayValue ?? []
        let ids = list.compactMap { course -> String? in
            course["id"]?.stringValue
        }
        return Identity(userID: userID, courseIDs: ids)
    }

    static func parse(_ event: JSONValue) -> ClassEvent {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ key: String) -> Date? {
            guard let text = event[key]?.stringValue else { return nil }
            return iso.date(from: text) ?? isoPlain.date(from: text)
        }
        return ClassEvent(
            title: event["title"]?.stringValue ?? "Class",
            courseName: event["courseName"]?.stringValue
                ?? event["course"]?.stringValue ?? "",
            teacher: event["teacherName"]?.stringValue ?? "",
            start: date("startAt"),
            end: date("endAt"),
            timeText: event["time"]?.stringValue ?? "",
            localDay: event["localDay"]?.stringValue ?? "",
            attendance: event["attendance"]?.stringValue ?? "",
            platform: event["platform"]?.stringValue ?? "",
            url: event["url"]?.stringValue)
    }

    // MARK: - Snapshots

    static func todaySnapshot(_ events: [ClassEvent]) -> DataSnapshot {
        let visible = events.filter { !$0.isHidden }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        guard !visible.isEmpty else {
            return .text("No classes today — day off 🎉")
        }
        let now = Date()
        let rows = visible.map { event -> [String] in
            var when = event.timeText
            if let start = event.start, let end = event.end, now >= start, now <= end {
                when = "● " + when
            } else if let end = event.end, now > end {
                when += " ✓"
            }
            return [when, event.displayName, event.isRequired ? "required" : ""]
        }
        return .table(TableData(columns: ["Time", "Class", ""], rows: rows))
    }

    static func nextSnapshot(_ events: [ClassEvent]) -> DataSnapshot {
        let now = Date()
        let visible = events.filter { !$0.isHidden }
        if let live = visible.first(where: { event in
            guard let start = event.start, let end = event.end else { return false }
            return now >= start && now <= end
        }) {
            var text = "● Now · \(live.displayName)\n\(live.timeText)"
            if !live.teacher.isEmpty { text += "\n\(live.teacher)" }
            return .text(text)
        }
        let upcoming = visible
            .filter { ($0.start ?? .distantPast) > now }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        guard let next = upcoming.first else {
            return .text("Nothing else today 🎉")
        }
        var text = "Next · \(next.displayName)\n\(next.timeText)"
        if next.isRequired { text += "  (required)" }
        if !next.teacher.isEmpty { text += "\n\(next.teacher)" }
        return .text(text)
    }

    static func weekSnapshot(_ events: [ClassEvent]) -> DataSnapshot {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"

        let rows = events
            .filter { event in
                guard let date = event.start, !event.isHidden else { return false }
                return date >= start && date < end
            }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            .map { event -> [String] in
                [event.start.map { formatter.string(from: $0) } ?? "",
                 event.timeText,
                 event.displayName]
            }
        guard !rows.isEmpty else { return .text("No classes scheduled this week") }
        return .table(TableData(columns: ["Day", "Time", "Class"], rows: rows))
    }

    static func coursesSnapshot(portal: String) async throws -> DataSnapshot {
        let identity = try await identity(portal: portal)
        let json = try await K12Session.shared.json(path: "/api/courses/\(identity.userID)",
                                                     portal: portal)
        let list = json["data"]?.arrayValue ?? json["courses"]?.arrayValue ?? []
        let rows = list.compactMap { course -> [String]? in
            guard let name = course["name"]?.stringValue else { return nil }
            let teacher = course["teacherName"]?.stringValue ?? ""
            let grade = course["grade"]?.objectValue?["current_score"]?.doubleValue
                ?? course["grade"]?.doubleValue
            let gradeText = grade.map { $0 == $0.rounded() ? "\(Int($0))%" : String(format: "%.1f%%", $0) } ?? ""
            return [CanvasSource.shortCourseName(name), teacher, gradeText]
        }
        guard !rows.isEmpty else { return .text("No courses found") }
        return .table(TableData(columns: ["Course", "Teacher", "Grade"], rows: rows))
    }
}
