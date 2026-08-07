import SwiftUI

/// Shared helpers for the school panels.
enum SchoolStyle {
    /// Grade colors run green → amber → red so a wall of classes reads at a
    /// glance from across the room.
    static func color(forScore score: Double?, in sbStyle: SBPanelStyle) -> Color {
        guard let score else { return sbStyle.textSecondary }
        switch score {
        case 90...: return sbStyle.good
        case 80..<90: return Color(hex: 0x9ACD32)
        case 70..<80: return sbStyle.warn
        case 60..<70: return Color(hex: 0xFF8C42)
        default: return sbStyle.bad
        }
    }

    /// "in 42m", "in 2h 15m", "now".
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let minutes = seconds / 60
        if minutes < 1 { return "in <1m" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }

    static func alias(_ name: String, in settings: PanelSettings) -> String {
        settings.courseAliases[name].flatMap { $0.isEmpty ? nil : $0 } ?? name
    }
}

// MARK: - Grades

struct GradesPanelView: View {
    @Environment(\.sbStyle) private var sbStyle
    let grades: [CourseGrade]
    let settings: PanelSettings

    var body: some View {
        let visible = settings.visibleGrades(grades)
        if visible.isEmpty && !grades.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(sbStyle.textSecondary)
                Text("Every class is hidden")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(sbStyle.textPrimary)
                Text("Check one again in the panel's settings.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(sbStyle.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(visible) { grade in
                        row(grade)
                    }
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func row(_ grade: CourseGrade) -> some View {
        let tint = SchoolStyle.color(forScore: grade.score, in: sbStyle)
        let content = HStack(spacing: 10) {
            // Letter badge carries the color, so the row scans instantly.
            Text(grade.displayLetter)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(SBTheme.background)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(SchoolStyle.alias(grade.course, in: settings))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(sbStyle.textPrimary)
                        .lineLimit(1)
                    // Says the standing is provisional, so a low number — or a
                    // dash — reads as "not marked yet" rather than "doing badly".
                    if grade.ungradedCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(grade.ungradedCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(sbStyle.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(sbStyle.separator, in: Capsule())
                        .accessibilityLabel("\(grade.ungradedCount) not graded yet")
                    }
                }
                // A slim bar makes relative standing obvious without a chart.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(sbStyle.separator)
                        Capsule().fill(tint)
                            .frame(width: max(3, proxy.size.width * min(1, (grade.score ?? 0) / 100)))
                    }
                }
                .frame(height: 5)
            }

            Text(grade.score.map { $0 == $0.rounded() ? "\(Int($0))%" : String(format: "%.1f%%", $0) } ?? "—")
                .font(SBTheme.lcdFont(size: 17))
                .foregroundStyle(tint)
                .frame(minWidth: 56, alignment: .trailing)
        }

        #if os(tvOS) || os(watchOS)
        content
        #else
        if let urlString = grade.url, let url = URL(string: urlString) {
            Link(destination: url) { content }.buttonStyle(.plain)
        } else {
            content
        }
        #endif
    }
}

// MARK: - Schedule

struct SchedulePanelView: View {
    @Environment(\.sbStyle) private var sbStyle
    let classes: [ScheduledClass]
    let settings: PanelSettings

    var body: some View {
        // Re-renders every 30s so the countdown stays honest.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let remaining = classes.filter { !$0.hasEnded(at: now) }
            if classes.isEmpty {
                emptyState("No classes today", detail: "Enjoy the day off 🎉")
            } else if remaining.isEmpty {
                emptyState("All done for today", detail: "\(classes.count) class\(classes.count == 1 ? "" : "es") finished ✓")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(remaining) { item in
                            row(item, now: now)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26))
                .foregroundStyle(sbStyle.good)
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(sbStyle.textPrimary)
            Text(detail)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(sbStyle.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ item: ScheduledClass, now: Date) -> some View {
        let live = item.isLive(at: now)
        let tint = live ? sbStyle.good : (item.attendanceRequired ? sbStyle.accent : SBTheme.secondaryAccent)
        let content = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.timeText)
                    .font(SBTheme.lcdFont(size: 15))
                    .foregroundStyle(tint)
                if live {
                    Text("● now")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(sbStyle.good)
                } else if let start = item.start {
                    Text(SchoolStyle.countdown(to: start, from: now))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(sbStyle.textSecondary)
                }
            }
            .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(SchoolStyle.alias(item.course, in: settings))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(sbStyle.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if item.attendanceRequired {
                        Text("REQUIRED")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .kerning(0.5)
                            .foregroundStyle(SBTheme.accent)
                    }
                    if let teacher = item.teacher {
                        Text(teacher)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(sbStyle.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            #if !os(tvOS) && !os(watchOS)
            if item.url != nil {
                Image(systemName: live ? "video.fill" : "chevron.right")
                    .font(.system(size: live ? 13 : 11, weight: .bold))
                    .foregroundStyle(live ? sbStyle.good : sbStyle.textSecondary)
            }
            #endif
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(live ? sbStyle.good.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        #if os(tvOS) || os(watchOS)
        content
        #else
        if let urlString = item.url, let url = URL(string: urlString) {
            Link(destination: url) { content }.buttonStyle(.plain)
        } else {
            content
        }
        #endif
    }
}

// MARK: - Assignments

struct AssignmentsPanelView: View {
    @Environment(\.sbStyle) private var sbStyle
    let digest: AssignmentDigest
    let settings: PanelSettings

    var body: some View {
        if digest.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(sbStyle.good)
                Text("All caught up")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(sbStyle.textPrimary)
                if digest.awaitingGrading > 0 {
                    Text("\(digest.awaitingGrading) waiting to be graded")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(sbStyle.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Late", items: digest.late, tint: sbStyle.bad,
                            icon: "exclamationmark.triangle.fill")
                    section("Due Today", items: digest.due, tint: SBTheme.accent,
                            icon: "clock.fill")
                    section("Re-Do", items: digest.redo, tint: sbStyle.warn,
                            icon: "arrow.uturn.backward.circle.fill")
                    if digest.awaitingGrading > 0 {
                        Text("\(digest.awaitingGrading) submitted, waiting on a grade")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(sbStyle.textSecondary)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [AssignmentItem],
                         tint: Color, icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                    Text(title.uppercased())
                        .font(SBTheme.titleFont(size: 10))
                        .kerning(1.2)
                    Text("\(items.count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.25), in: Capsule())
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)

                ForEach(items) { item in
                    row(item, tint: tint)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: AssignmentItem, tint: Color) -> some View {
        let content = HStack(spacing: 8) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(sbStyle.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if !item.course.isEmpty {
                        Text(SchoolStyle.alias(item.course, in: settings))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(sbStyle.textSecondary)
                            .lineLimit(1)
                    }
                    if item.state == .redo, let scoreText = item.scoreText {
                        Text(scoreText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                        if let percent = item.percent {
                            Text("\(Int(percent.rounded()))%")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(sbStyle.textSecondary)
                        }
                    } else if let due = item.due {
                        Text(item.state == .late
                             ? "was due \(due.formatted(.dateTime.month(.abbreviated).day()))"
                             : due.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(sbStyle.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            #if !os(tvOS) && !os(watchOS)
            if item.url != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(sbStyle.textSecondary)
            }
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)

        #if os(tvOS) || os(watchOS)
        content
        #else
        if let urlString = item.url, let url = URL(string: urlString) {
            Link(destination: url) { content }.buttonStyle(.plain)
        } else {
            content
        }
        #endif
    }
}
