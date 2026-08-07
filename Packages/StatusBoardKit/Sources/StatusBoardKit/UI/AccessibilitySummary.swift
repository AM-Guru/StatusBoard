import Foundation

/// Spoken descriptions of panel data for VoiceOver. A dashboard is a wall of
/// glanceable numbers — for a VoiceOver user each panel needs to summarize
/// itself in one sentence rather than exposing dozens of unlabeled shapes.
public enum AccessibilitySummary {

    /// The value portion, e.g. "67 percent" or "3 of 5 services down".
    public static func value(for snapshot: DataSnapshot?, settings: PanelSettings) -> String {
        guard let snapshot else { return "Waiting for data" }
        switch snapshot {
        case .text(let text):
            return text

        case .number(let value, let unit):
            return spoken(number: value, unit: unit ?? settings.unit)

        case .series(let series):
            guard let last = series.points.last else { return "No data points" }
            let values = series.points.map(\.value)
            let minimum = values.min() ?? last.value
            let maximum = values.max() ?? last.value
            var text = "Latest \(spoken(number: last.value, unit: series.unit ?? settings.unit))"
            if series.points.count > 1 {
                text += ", \(series.points.count) points"
                text += ", ranging from \(spoken(number: minimum, unit: nil))"
                text += " to \(spoken(number: maximum, unit: nil))"
                if let first = values.first {
                    let change = last.value - first
                    if abs(change) > .ulpOfOne {
                        text += change > 0 ? ", trending up" : ", trending down"
                    }
                }
            }
            return text

        case .table(let table):
            let columns = table.columns.isEmpty ? "" : ", columns \(list(table.columns))"
            return "Table with \(count(table.rows.count, "row"))\(columns)"

        case .feed(let items):
            guard let first = items.first else { return "No items" }
            // VoiceOver can't see the site icons, so the source is spoken.
            let sources = Set(items.compactMap(\.sourceName)).count
            let from = first.sourceName.map { ", from \($0)" } ?? ""
            let across = sources > 1 ? " across \(count(sources, "source"))" : ""
            return "\(count(items.count, "item"))\(across). Latest: \(first.title)\(from)"

        case .weather(let report):
            var text = "\(Int(report.temperatureC.rounded())) degrees celsius, \(report.conditionDescription)"
            if let location = report.locationName.isEmpty ? nil : report.locationName {
                text = "\(location): " + text
            }
            if let today = report.days.first {
                text += ". Today's high \(Int(today.highC.rounded())), low \(Int(today.lowC.rounded()))"
            }
            return text

        case .statuses(let statuses):
            guard !statuses.isEmpty else { return "No services configured" }
            let down = statuses.filter { $0.state == .down }
            let degraded = statuses.filter { $0.state == .degraded }
            if down.isEmpty && degraded.isEmpty {
                return "All \(count(statuses.count, "service")) up"
            }
            var parts: [String] = []
            if !down.isEmpty { parts.append("\(list(down.map(\.name))) down") }
            if !degraded.isEmpty { parts.append("\(list(degraded.map(\.name))) degraded") }
            return parts.joined(separator: ", ")

        case .grades(let all):
            guard !all.isEmpty else { return "No grades" }
            // Reads what's on screen: unchecked classes aren't spoken either.
            let grades = settings.visibleGrades(all)
            guard !grades.isEmpty else { return "Every class is hidden" }
            return grades.map { grade in
                let score = grade.score.map { "\(Int($0.rounded())) percent" } ?? "nothing graded yet"
                // The hourglass badge is a shape VoiceOver can't see.
                let pending = grade.ungradedCount > 0
                    ? ", \(count(grade.ungradedCount, "assignment")) not graded yet"
                    : ""
                return "\(grade.course), \(score)\(pending)"
            }.joined(separator: ". ")

        case .schedule(let classes):
            let remaining = classes.filter { !$0.hasEnded() }
            guard !classes.isEmpty else { return "No classes today" }
            guard let next = remaining.first else { return "All classes finished today" }
            var text = "\(count(remaining.count, "class")) left. Next: \(next.course) at \(next.timeText)"
            if let start = next.start {
                text += ", \(SchoolStyle.countdown(to: start))"
            }
            return text

        case .assignments(let digest):
            guard !digest.isEmpty else { return "All caught up" }
            var parts: [String] = []
            if !digest.late.isEmpty { parts.append("\(count(digest.late.count, "late assignment"))") }
            if !digest.due.isEmpty { parts.append("\(count(digest.due.count, "due today"))") }
            if !digest.redo.isEmpty { parts.append("\(count(digest.redo.count, "to redo"))") }
            return list(parts)

        case .vehicle(let vehicle):
            return TessieReadout.summary(for: vehicle, settings: settings)

        case .homeSensors(let report):
            return HomeReadout.summary(report: report, settings: settings)

        case .thermostat(let readout):
            return HomeReadout.summary(thermostat: readout, settings: settings)

        case .image:
            return "Image"

        case .error(let message):
            return "Error: \(message)"
        }
    }

    /// The whole panel: title, kind, and value — what VoiceOver reads when the
    /// panel gets focus.
    public static func panelLabel(_ panel: Panel, snapshot: DataSnapshot?) -> String {
        let title = panel.title.isEmpty ? panel.kind.displayName : panel.title

        switch panel.kind {
        case .clock:
            let zone = panel.settings.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
            let formatter = DateFormatter()
            formatter.timeZone = zone
            formatter.timeStyle = .short
            return "\(title). \(formatter.string(from: Date()))"

        case .countdown:
            guard let target = panel.settings.targetDate else {
                return "\(title). No target date set"
            }
            let remaining = target.timeIntervalSinceNow
            if remaining <= 0 { return "\(title). Time elapsed" }
            let days = Int(remaining) / 86400
            let hours = Int(remaining) % 86400 / 3600
            let minutes = Int(remaining) % 3600 / 60
            var parts: [String] = []
            if days > 0 { parts.append(count(days, "day")) }
            if hours > 0 { parts.append(count(hours, "hour")) }
            if days == 0 && minutes > 0 { parts.append(count(minutes, "minute")) }
            return "\(title). \(parts.isEmpty ? "Less than a minute" : list(parts)) remaining"

        case .text:
            return "\(title). \(panel.settings.text ?? "No text")"

        case .webClip:
            return "\(title). Web clip of \(panel.settings.url ?? "no page")"

        case .progress:
            guard case .number(let value, _)? = snapshot else {
                return "\(title). Waiting for data"
            }
            let fraction: Double
            if let total = panel.settings.progressTotal, total > 0 {
                fraction = value / total
            } else {
                fraction = value <= 1 ? value : value / 100
            }
            return "\(title). \(Int((min(1, max(0, fraction)) * 100).rounded())) percent"

        default:
            return "\(title). \(value(for: snapshot, settings: panel.settings))"
        }
    }

    // MARK: - Formatting helpers

    static func spoken(number: Double, unit: String?) -> String {
        let text: String
        if number == number.rounded() && abs(number) < 1e15 {
            text = Int(number).formatted()
        } else {
            text = number.formatted(.number.precision(.fractionLength(0...1)))
        }
        guard let unit, !unit.isEmpty else { return text }
        // Speak common symbols as words.
        switch unit {
        case "%": return "\(text) percent"
        case "°", "°C": return "\(text) degrees"
        default: return "\(text) \(unit)"
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }
}
