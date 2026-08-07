import Foundation

/// Turns home data into sentences and series.
///
/// It lives outside SwiftUI for the same reason `TessieReadout` does: the
/// panel, the VoiceOver summary, the watch and the Lock Screen widget all
/// need to say the same thing about the same reading, and only one of them
/// is a view.
public enum HomeReadout {

    // MARK: - History

    /// The file a thermostat's samples accumulate in.
    ///
    /// Keyed by the *device*, not the panel: a thermostat panel and a trend
    /// panel watching the same unit should build one shared history rather
    /// than two half-length ones, and moving a panel between boards must not
    /// throw its history away.
    public static func historyKey(for readout: ThermostatReadout) -> String {
        "\(readout.sourceLabel ?? "home")-\(readout.id)"
    }

    /// Records this reading and hangs the recent history and the diagnosis
    /// off the readout. Every provider calls this, which is what makes the
    /// trend chart and the equipment warnings work identically for all three.
    public static func attachHistory(to readout: inout ThermostatReadout,
                                     settings: PanelSettings,
                                     now: Date = Date()) async {
        let key = historyKey(for: readout)
        let sample = HVACSample(date: readout.updatedAt ?? now,
                                indoorC: readout.currentC,
                                targetC: readout.activeSetpointC,
                                outdoorC: readout.outdoorC,
                                humidity: readout.humidity,
                                status: readout.status)
        let history = await HVACHistoryStore.shared.record(sample, for: key)
        attach(history: history, to: &readout, settings: settings, now: now)
    }

    /// The same, for history that was already loaded — used after a backfill.
    public static func attach(history: [HVACSample],
                              to readout: inout ThermostatReadout,
                              settings: PanelSettings,
                              now: Date = Date()) {
        let hours = settings.resolvedTrendHours
        let cutoff = now.addingTimeInterval(-hours * 3600)
        // The chart is a few hundred points wide at most, and the snapshot it
        // rides in is rewritten every refresh and mirrored to the widget
        // container — so it carries a drawn-resolution copy while the
        // analysis keeps the full-rate history.
        readout.samples = downsample(history.filter { $0.date >= cutoff }, to: 240)
        readout.diagnostics = HVACAnalyzer.analyze(samples: history, windowHours: hours, now: now)
    }

    /// Thins a series by averaging within evenly spaced buckets, keeping the
    /// status of whatever was conditioning inside each — dropping every other
    /// sample instead would erase exactly the short runs the panel exists to
    /// show.
    public static func downsample(_ samples: [HVACSample], to limit: Int) -> [HVACSample] {
        guard samples.count > limit, limit > 1,
              let first = samples.first, let last = samples.last else { return samples }
        let span = last.date.timeIntervalSince(first.date)
        guard span > 0 else { return samples }
        let bucketSeconds = span / Double(limit)

        var result: [HVACSample] = []
        var bucket: [HVACSample] = []
        var bucketEnd = first.date.addingTimeInterval(bucketSeconds)

        func flush() {
            guard !bucket.isEmpty else { return }
            result.append(merge(bucket))
            bucket.removeAll(keepingCapacity: true)
        }

        for sample in samples {
            while sample.date > bucketEnd {
                flush()
                bucketEnd = bucketEnd.addingTimeInterval(bucketSeconds)
            }
            bucket.append(sample)
        }
        flush()
        return result
    }

    private static func merge(_ bucket: [HVACSample]) -> HVACSample {
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        // Any conditioning inside the bucket wins over idle: a bucket that
        // was cooling for part of it was not idle.
        let status = bucket.first(where: { $0.status.isConditioning })?.status
            ?? bucket.last?.status ?? .unknown
        return HVACSample(date: bucket[bucket.count / 2].date,
                          indoorC: mean(bucket.compactMap(\.indoorC)),
                          targetC: mean(bucket.compactMap(\.targetC)),
                          outdoorC: mean(bucket.compactMap(\.outdoorC)),
                          humidity: mean(bucket.compactMap(\.humidity)),
                          status: status)
    }

    // MARK: - Summaries

    /// One line for a sensor panel — what VoiceOver reads and what a Lock
    /// Screen complication shows.
    public static func summary(report: HomeSensorReport, settings: PanelSettings) -> String {
        guard !report.isEmpty else { return "No sensors reporting" }
        let units = settings.weatherUnits

        if settings.homeMode == .activity {
            let active = report.activeReadings
            guard !active.isEmpty else { return "All quiet" }
            let names = active.prefix(3).map { reading -> String in
                let place = reading.room ?? reading.name
                return "\(reading.displayValue(units: units).lowercased()) in \(place)"
            }
            let extra = active.count > 3 ? ", and \(active.count - 3) more" : ""
            return names.joined(separator: ", ") + extra
        }

        let temperatures = report.readings.filter { $0.kind == .temperature }
        if !temperatures.isEmpty {
            let warmest = temperatures.max { ($0.value ?? 0) < ($1.value ?? 0) }
            let coolest = temperatures.min { ($0.value ?? 0) < ($1.value ?? 0) }
            guard let warmest, let coolest, let high = warmest.value, let low = coolest.value else {
                return "\(temperatures.count) rooms reporting"
            }
            if warmest.id == coolest.id {
                return "\(warmest.room ?? warmest.name) \(SBTemperature.full(high, units: units))"
            }
            return "\(temperatures.count) rooms, \(SBTemperature.full(low, units: units)) in \(coolest.room ?? coolest.name) to \(SBTemperature.full(high, units: units)) in \(warmest.room ?? warmest.name)"
        }

        let parts = report.readings.prefix(3).map {
            "\($0.name) \($0.displayValue(units: units))"
        }
        return parts.joined(separator: ", ")
    }

    /// The compact form for accessory widget families, where one fact fits.
    public static func compactSummary(report: HomeSensorReport,
                                      settings: PanelSettings) -> String {
        if settings.homeMode == .activity {
            let active = report.activeReadings.count
            return active == 0 ? "Quiet" : "\(active) active"
        }
        if let average = report.averageTemperatureC {
            return SBTemperature.short(average, units: settings.weatherUnits)
        }
        return report.isEmpty ? "—" : "\(report.readings.count)"
    }

    /// One line for a thermostat panel.
    public static func summary(thermostat: ThermostatReadout,
                               settings: PanelSettings) -> String {
        let units = settings.weatherUnits
        guard thermostat.isOnline else { return "\(thermostat.name) is offline" }

        var parts: [String] = []
        if let current = thermostat.currentC {
            parts.append(SBTemperature.full(current, units: units))
        }
        if let setpoint = thermostat.setpointText(units: units) {
            parts.append("set to \(setpoint)")
        }
        switch thermostat.status {
        case .heating, .cooling:
            parts.append(thermostat.status.displayName.lowercased())
        case .off where thermostat.mode != .off:
            parts.append("idle")
        case .off:
            parts.append("off")
        default:
            break
        }
        if let humidity = thermostat.humidity {
            parts.append("\(Int(humidity.rounded()))% humidity")
        }

        if settings.homeMode == .diagnostics || settings.showsHVACDiagnostics,
           let issue = thermostat.diagnostics?.issues.first,
           issue.severity >= .warning {
            parts.append(issue.title.lowercased())
        }
        return parts.isEmpty ? thermostat.name : parts.joined(separator: ", ")
    }

    public static func compactSummary(thermostat: ThermostatReadout,
                                      settings: PanelSettings) -> String {
        guard let current = thermostat.currentC else {
            return thermostat.isOnline ? thermostat.mode.displayName : "Offline"
        }
        let temperature = SBTemperature.short(current, units: settings.weatherUnits)
        switch thermostat.status {
        case .heating: return "\(temperature) ↑"
        case .cooling: return "\(temperature) ↓"
        default: return temperature
        }
    }

    /// The equipment-health headline: what a diagnostics panel says at a
    /// glance, and how a thermostat panel decides whether to shout.
    public static func healthHeadline(_ diagnostics: HVACDiagnostics?) -> (text: String, severity: HVACIssue.Severity) {
        guard let diagnostics else { return ("Watching", .info) }
        guard diagnostics.hasEnoughHistory else {
            return ("Still learning", .info)
        }
        guard let worst = diagnostics.issues.first else {
            return ("Running normally", .info)
        }
        return (worst.title, worst.severity)
    }
}
