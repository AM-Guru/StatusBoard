import Foundation

/// One course's standing, for the Grades panel.
public struct CourseGrade: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var course: String
    /// Percentage, 0–100, over work that has actually been marked. `nil` when
    /// nothing in the course has been graded yet — which is not the same as
    /// zero, and is why the panel shows a dash rather than an F.
    public var score: Double?
    public var letter: String?
    public var teacher: String?
    public var url: String?
    /// Assignments handed in and waiting on a grade, plus the zeros a school's
    /// missing-work policy fills in before a teacher has actually marked
    /// anything. Left out of `score`, and shown as a badge so a course whose
    /// standing is still provisional says so.
    public var ungradedCount: Int = 0

    public init(id: String = UUID().uuidString, course: String, score: Double? = nil,
                letter: String? = nil, teacher: String? = nil, url: String? = nil,
                ungradedCount: Int = 0) {
        self.id = id
        self.course = course
        self.score = score
        self.letter = letter
        self.teacher = teacher
        self.url = url
        self.ungradedCount = ungradedCount
    }

    // Written by hand because a synthesized decoder throws on a key it doesn't
    // find, defaulted property or not — a snapshot saved by an older build, or
    // synced from a device still running one, would fail to load entirely.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        course = try container.decode(String.self, forKey: .course)
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        letter = try container.decodeIfPresent(String.self, forKey: .letter)
        teacher = try container.decodeIfPresent(String.self, forKey: .teacher)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        ungradedCount = try container.decodeIfPresent(Int.self, forKey: .ungradedCount) ?? 0
    }

    /// Letter derived from the score when the school doesn't publish one.
    public var displayLetter: String {
        if let letter, !letter.isEmpty { return letter }
        guard let score else { return "—" }
        switch score {
        case 90...: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default: return "F"
        }
    }
}

/// One class meeting, for the Schedule panel.
public struct ScheduledClass: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var course: String
    public var start: Date?
    public var end: Date?
    /// Pre-formatted school-local time, e.g. "1:30 PM".
    public var timeText: String
    public var teacher: String?
    public var attendanceRequired: Bool
    public var url: String?

    public init(id: String = UUID().uuidString, course: String, start: Date? = nil,
                end: Date? = nil, timeText: String = "", teacher: String? = nil,
                attendanceRequired: Bool = false, url: String? = nil) {
        self.id = id
        self.course = course
        self.start = start
        self.end = end
        self.timeText = timeText
        self.teacher = teacher
        self.attendanceRequired = attendanceRequired
        self.url = url
    }

    public func isLive(at date: Date = Date()) -> Bool {
        guard let start, let end else { return false }
        return date >= start && date <= end
    }

    public func hasEnded(at date: Date = Date()) -> Bool {
        guard let end else { return false }
        return date > end
    }
}

/// Where an assignment sits in the student's workflow.
public enum AssignmentState: String, Codable, Sendable {
    /// Due today and not handed in.
    case dueToday
    /// Past due and missing, or flagged late and still not in.
    case late
    /// Graded below full marks — worth another attempt.
    case redo
}

public struct AssignmentItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var course: String
    public var due: Date?
    public var url: String?
    public var state: AssignmentState
    public var score: Double?
    public var pointsPossible: Double?

    public init(id: String = UUID().uuidString, title: String, course: String,
                due: Date? = nil, url: String? = nil, state: AssignmentState,
                score: Double? = nil, pointsPossible: Double? = nil) {
        self.id = id
        self.title = title
        self.course = course
        self.due = due
        self.url = url
        self.state = state
        self.score = score
        self.pointsPossible = pointsPossible
    }

    /// "18/20" when both are known.
    public var scoreText: String? {
        guard let score, let pointsPossible, pointsPossible > 0 else { return nil }
        let earned = score == score.rounded() ? String(Int(score)) : String(format: "%.1f", score)
        let total = pointsPossible == pointsPossible.rounded()
            ? String(Int(pointsPossible)) : String(format: "%.1f", pointsPossible)
        return "\(earned)/\(total)"
    }

    public var percent: Double? {
        guard let score, let pointsPossible, pointsPossible > 0 else { return nil }
        return score / pointsPossible * 100
    }
}

/// The Assignments panel's whole payload: what's due, what's overdue, and what
/// came back below full marks. Anything finished at 100% — or handed in and
/// waiting on a grade — is deliberately absent.
public struct AssignmentDigest: Codable, Hashable, Sendable {
    public var due: [AssignmentItem]
    public var late: [AssignmentItem]
    public var redo: [AssignmentItem]
    /// Handed in and awaiting a grade; counted but not listed.
    public var awaitingGrading: Int

    public init(due: [AssignmentItem] = [], late: [AssignmentItem] = [],
                redo: [AssignmentItem] = [], awaitingGrading: Int = 0) {
        self.due = due
        self.late = late
        self.redo = redo
        self.awaitingGrading = awaitingGrading
    }

    public var isEmpty: Bool { due.isEmpty && late.isEmpty && redo.isEmpty }
    public var actionableCount: Int { due.count + late.count + redo.count }
}
