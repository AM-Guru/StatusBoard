import Foundation

/// Grades for every active course, from Canvas.
public enum GradesSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        // Falls back to whatever another Canvas panel was signed in with.
        let config = await CanvasCredentials.resolved(settings.connector)
        guard var host = config.projectURL?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              let token = config.token, !token.isEmpty else {
            return .error("Enter your Canvas URL and access token in the panel settings")
        }
        if !host.contains("://") { host = "https://" + host }
        if host.hasSuffix("/") { host.removeLast() }

        do {
            let json = try await CanvasSource.request(
                host: host, token: token,
                path: "/api/v1/courses?enrollment_state=active&include[]=total_scores&per_page=50")
            var grades: [CourseGrade] = []
            for course in json.arrayValue ?? [] {
                guard let name = course["name"]?.stringValue,
                      let id = course["id"]?.stringValue else { continue }
                let enrollment = (course["enrollments"]?.arrayValue ?? []).first {
                    $0["type"]?.stringValue == "student" || $0["computed_current_score"] != nil
                }
                grades.append(CourseGrade(
                    id: id,
                    course: CanvasSource.shortCourseName(name),
                    score: enrollment?["computed_current_score"]?.doubleValue,
                    letter: enrollment?["computed_current_letter_grade"]?.stringValue
                        ?? enrollment?["computed_current_grade"]?.stringValue,
                    teacher: nil,
                    url: "\(host)/courses/\(id)/grades"))
            }
            guard !grades.isEmpty else { return .error("No active courses") }
            grades.sort { ($0.score ?? -1) > ($1.score ?? -1) }
            return .grades(grades)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Today's remaining class meetings, from the K12 portal.
public enum ScheduleSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        let config = settings.connector ?? ConnectorConfig()
        let portal = (config.projectURL?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? K12Session.defaultPortal
        do {
            let events = try await K12OLSSource.todayClasses(portal: portal)
            let classes = events
                .filter { !$0.isHidden }
                .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
                .map { event in
                    ScheduledClass(course: event.displayName,
                                   start: event.start,
                                   end: event.end,
                                   timeText: event.timeText,
                                   teacher: event.teacher.isEmpty ? nil : event.teacher,
                                   attendanceRequired: event.isRequired,
                                   url: event.url)
                }
            return .schedule(classes)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Assignments split into what's due, what's overdue, and what came back below
/// full marks — the "re-do" pile.
///
/// Canvas's per-course submissions endpoint is the only place that carries
/// both the grade and the assignment together, so this fans out one request
/// per active course and merges the results.
public enum AssignmentsSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        // Falls back to whatever another Canvas panel was signed in with.
        let config = await CanvasCredentials.resolved(settings.connector)
        guard var host = config.projectURL?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
              let token = config.token, !token.isEmpty else {
            return .error("Enter your Canvas URL and access token in the panel settings")
        }
        if !host.contains("://") { host = "https://" + host }
        if host.hasSuffix("/") { host.removeLast() }

        do {
            let coursesJSON = try await CanvasSource.request(
                host: host, token: token,
                path: "/api/v1/courses?enrollment_state=active&per_page=50")
            let courses = (coursesJSON.arrayValue ?? []).compactMap { course -> (String, String)? in
                guard let id = course["id"]?.stringValue,
                      let name = course["name"]?.stringValue else { return nil }
                return (id, CanvasSource.shortCourseName(name))
            }
            guard !courses.isEmpty else { return .error("No active courses") }

            // One request per course, in parallel.
            var digest = AssignmentDigest()
            try await withThrowingTaskGroup(of: [JSONValue].self) { group in
                for (id, _) in courses {
                    group.addTask {
                        let json = try await CanvasSource.request(
                            host: host, token: token,
                            path: "/api/v1/courses/\(id)/students/submissions"
                                + "?student_ids[]=self&include[]=assignment&per_page=100")
                        return json.arrayValue ?? []
                    }
                }
                let names = Dictionary(uniqueKeysWithValues: courses)
                for try await submissions in group {
                    for submission in submissions {
                        classify(submission, courseNames: names, into: &digest)
                    }
                }
            }

            digest.due.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            digest.late.sort { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) }
            digest.redo.sort { ($0.percent ?? 100) < ($1.percent ?? 100) }
            return .assignments(digest)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// The rules the panel is built around:
    /// finished at full marks → hidden; handed in and waiting → counted only;
    /// graded below full marks → re-do; missing/late → late; due today → due.
    static func classify(_ submission: JSONValue, courseNames: [String: String],
                         into digest: inout AssignmentDigest, now: Date = Date()) {
        guard let assignment = submission["assignment"] else { return }
        let title = assignment["name"]?.stringValue ?? "Assignment"
        let courseID = assignment["course_id"]?.stringValue
            ?? submission["course_id"]?.stringValue ?? ""
        let course = courseNames[courseID] ?? ""
        let url = assignment["html_url"]?.stringValue
        let due = assignment["due_at"]?.stringValue.flatMap { try? Date($0, strategy: .iso8601) }
        let points = assignment["points_possible"]?.doubleValue
        let identifier = submission["id"]?.stringValue ?? UUID().uuidString

        let state = submission["workflow_state"]?.stringValue ?? ""
        let score = submission["score"]?.doubleValue
        let excused = submission["excused"]?.doubleValue == 1
        let missing = submission["missing"]?.doubleValue == 1
        let late = submission["late"]?.doubleValue == 1
        if excused { return }

        if state == "graded", let score {
            // Full marks (or ungraded-for-points work) is done — hide it.
            guard let points, points > 0, score < points else { return }
            digest.redo.append(AssignmentItem(id: identifier, title: title, course: course,
                                              due: due, url: url, state: .redo,
                                              score: score, pointsPossible: points))
            return
        }
        if state == "submitted" || state == "pending_review" {
            digest.awaitingGrading += 1
            return
        }
        if missing || (late && state != "graded") {
            digest.late.append(AssignmentItem(id: identifier, title: title, course: course,
                                              due: due, url: url, state: .late,
                                              pointsPossible: points))
            return
        }
        if let due, Calendar.current.isDate(due, inSameDayAs: now) {
            digest.due.append(AssignmentItem(id: identifier, title: title, course: course,
                                             due: due, url: url, state: .dueToday,
                                             pointsPossible: points))
        }
    }
}
