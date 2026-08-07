import Foundation

/// Turns a recorded history of thermostat samples into something worth
/// saying about the equipment.
///
/// No provider offers this. HomeKit, Home Assistant and Nest all report what
/// the system is doing *now*; the interesting facts — how often it starts,
/// how long it runs, whether it is getting anywhere — only exist in the shape
/// of that value over hours. So Status Board records its own samples and
/// works them out here.
///
/// Two rules run through all of it. First, every claim carries the numbers
/// behind it, because a diagnosis nobody can check is worse than none.
/// Second, nothing is asserted that the sampling rate cannot support: runs
/// are measured to the nearest sample, so a panel refreshing every five
/// minutes is told its resolution rather than allowed to imply five-second
/// precision. Pure Foundation, so it is unit-testable without a house.
public enum HVACAnalyzer {

    /// A contiguous stretch with the same status.
    struct Run: Equatable {
        var status: HVACStatus
        var start: Date
        var end: Date
        /// False for the first and last run in the window, whose real
        /// boundaries lie outside it — counting those as complete cycles
        /// makes every window look like it starts and ends mid-cycle.
        var isComplete: Bool

        var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    // MARK: - Entry point

    /// - Parameters:
    ///   - samples: recorded oldest-first. Anything older than the window is
    ///     ignored rather than trimmed, so the caller can keep one long file.
    ///   - windowHours: how far back to look.
    ///   - now: injectable so tests don't depend on the clock.
    public static func analyze(samples: [HVACSample],
                               windowHours: Double = 12,
                               now: Date = Date()) -> HVACDiagnostics {
        let cutoff = now.addingTimeInterval(-windowHours * 3600)
        let window = samples.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }

        guard let first = window.first, let last = window.last, window.count >= 2 else {
            return HVACDiagnostics(windowHours: windowHours,
                                   sampleCount: window.count,
                                   issues: [])
        }

        let spannedHours = last.date.timeIntervalSince(first.date) / 3600
        let resolution = medianGapMinutes(window)
        let runs = runs(in: window)
        let conditioning = runs.filter { $0.status.isConditioning }
        let completed = conditioning.filter(\.isComplete)

        let heatingMinutes = conditioning.filter { $0.status == .heating }
            .reduce(0) { $0 + $1.minutes }
        let coolingMinutes = conditioning.filter { $0.status == .cooling }
            .reduce(0) { $0 + $1.minutes }
        let spannedMinutes = max(1, spannedHours * 60)
        let runtimeFraction = min(1, (heatingMinutes + coolingMinutes) / spannedMinutes)

        // Off stretches *between* two runs — a trailing idle period tells you
        // nothing about how long the system rests.
        let idleGaps = runs.filter { !$0.status.isConditioning && $0.isComplete }

        var diagnostics = HVACDiagnostics(
            windowHours: windowHours,
            cycles: completed.count,
            cyclesPerHour: spannedHours > 0 ? Double(completed.count) / spannedHours : 0,
            averageRunMinutes: average(completed.map(\.minutes)),
            averageOffMinutes: average(idleGaps.map(\.minutes)),
            shortestRunMinutes: completed.map(\.minutes).min(),
            runtimeFraction: runtimeFraction,
            heatingMinutes: heatingMinutes,
            coolingMinutes: coolingMinutes,
            maxDeviationC: maxDeviation(window),
            resolutionMinutes: resolution,
            sampleCount: window.count,
            issues: [])

        diagnostics.issues = issues(window: window,
                                    runs: runs,
                                    completed: completed,
                                    diagnostics: diagnostics,
                                    spannedHours: spannedHours,
                                    now: now)
        return diagnostics
    }

    // MARK: - Runs

    /// Collapses samples into stretches of equal status.
    ///
    /// A sample's status is taken to hold until the next sample, which is the
    /// only assumption available and the reason `resolutionMinutes` is
    /// reported alongside every duration. `.unknown` samples break a run
    /// rather than extending it — a gap in data is not evidence of running.
    static func runs(in samples: [HVACSample]) -> [Run] {
        // The fan running on its own is not a cycle: a fan left on "circulate"
        // would otherwise read as one enormous run and hide every real one.
        guard samples.count >= 2 else { return [] }
        let statuses = samples.map { $0.status == .fan ? HVACStatus.off : $0.status }
        var result: [Run] = []
        var runStart = 0

        for index in 1..<samples.count where statuses[index] != statuses[runStart] {
            result.append(Run(status: statuses[runStart],
                              start: samples[runStart].date,
                              end: samples[index].date,
                              isComplete: true))
            runStart = index
        }
        result.append(Run(status: statuses[runStart], start: samples[runStart].date,
                          end: samples[samples.count - 1].date, isComplete: true))

        // The first run was already under way when the window opened and the
        // last has not finished, so both lengths are floors rather than
        // measurements. Counting them as cycles makes every window look like
        // it starts and ends mid-cycle.
        if !result.isEmpty {
            result[0].isComplete = false
            result[result.count - 1].isComplete = false
        }
        return result.filter { $0.status != .unknown }
    }

    // MARK: - Issues

    private static func issues(window: [HVACSample],
                               runs: [Run],
                               completed: [Run],
                               diagnostics: HVACDiagnostics,
                               spannedHours: Double,
                               now: Date) -> [HVACIssue] {
        var issues: [HVACIssue] = []

        // Nothing below means anything on twenty minutes of data.
        guard diagnostics.hasEnoughHistory else {
            return [HVACIssue(id: "warming-up", severity: .info,
                              title: "Still learning",
                              detail: "Status Board needs about an hour of readings before it can say anything about how the system is running. \(diagnostics.sampleCount) so far.")]
        }

        if let issue = staleData(window: window, resolution: diagnostics.resolutionMinutes, now: now) {
            // A thermostat that stopped reporting makes every other number
            // below meaningless, so it is the only thing worth saying.
            return [issue]
        }
        if let issue = shortCycling(completed: completed, diagnostics: diagnostics,
                                    spannedHours: spannedHours) {
            issues.append(issue)
        }
        if let issue = losingGround(runs: runs, window: window) {
            issues.append(issue)
        }
        if let issue = wrongDirection(runs: runs, window: window) {
            issues.append(issue)
        }
        if let issue = runningConstantly(diagnostics: diagnostics, spannedHours: spannedHours) {
            issues.append(issue)
        }
        if let issue = humidityWhileCooling(window: window) {
            issues.append(issue)
        }
        if let issue = wideSwing(window: window, diagnostics: diagnostics) {
            issues.append(issue)
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    /// The thermostat stopped answering.
    private static func staleData(window: [HVACSample], resolution: Double,
                                  now: Date) -> HVACIssue? {
        guard let last = window.last else { return nil }
        let ageMinutes = now.timeIntervalSince(last.date) / 60
        // Three missed samples, and never less than fifteen minutes — a slow
        // refresh shouldn't make the panel cry wolf.
        let limit = max(15, resolution * 3)
        guard ageMinutes > limit else { return nil }
        return HVACIssue(id: "stale", severity: .warning,
                         title: "No recent readings",
                         detail: "The last reading was \(minutes(ageMinutes)) ago. The thermostat may be offline, or Status Board may have been asleep.")
    }

    /// The headline check.
    ///
    /// Short cycling is a compressor or burner that starts and stops far more
    /// often than it should — it wastes energy, wears the equipment and never
    /// dehumidifies. The usual field rule of thumb is 2–3 cycles an hour with
    /// runs of at least ten minutes, so both halves have to be wrong before
    /// this fires: frequent *and* brief. A system cycling six times an hour
    /// with twelve-minute runs is just a mild day.
    private static func shortCycling(completed: [Run], diagnostics: HVACDiagnostics,
                                     spannedHours: Double) -> HVACIssue? {
        guard completed.count >= 3, spannedHours >= 1 else { return nil }
        let lengths = completed.map(\.minutes).sorted()
        let median = lengths[lengths.count / 2]
        guard diagnostics.cyclesPerHour >= 3, median < 10 else { return nil }

        // Very short runs relative to the sampling rate are real but their
        // measured length is not, and the wording has to reflect that.
        let precise = diagnostics.resolutionMinutes <= 2
        let severity: HVACIssue.Severity = median < 5 ? .critical : .warning
        var detail = "\(completed.count) cycles in \(hours(spannedHours)) — \(String(format: "%.1f", diagnostics.cyclesPerHour)) an hour, averaging \(minutes(median)) of runtime each. Healthy equipment usually runs 10–15 minutes at a time, 2–3 times an hour."
        if !precise {
            detail += " Sampled every \(minutes(diagnostics.resolutionMinutes)), so the run lengths are approximate — a faster refresh would sharpen them."
        }
        detail += " Common causes: an oversized system, a dirty filter or blocked returns, low refrigerant, or the thermostat sitting in a draft or in the sun."
        return HVACIssue(id: "short-cycling", severity: severity,
                         title: "Possible short cycling", detail: detail)
    }

    /// Running for a long stretch without closing the gap to the setpoint.
    private static func losingGround(runs: [Run], window: [HVACSample]) -> HVACIssue? {
        guard let longest = runs.filter({ $0.status.isConditioning })
            .max(by: { $0.minutes < $1.minutes }), longest.minutes >= 60 else { return nil }
        let inRun = window.filter { $0.date >= longest.start && $0.date <= longest.end }
        guard let firstDeviation = deviation(inRun.first),
              let lastDeviation = deviation(inRun.last) else { return nil }

        let closed = abs(firstDeviation) - abs(lastDeviation)
        guard abs(firstDeviation) >= 1.0, closed < 0.3 else { return nil }
        return HVACIssue(id: "no-progress", severity: .warning,
                         title: "Running without gaining ground",
                         detail: "\(longest.status.displayName.lowercased().capitalized) ran for \(minutes(longest.minutes)) and the room moved \(SBTemperature.delta(max(0, closed), units: .celsius)) closer to the setpoint, still \(SBTemperature.delta(abs(lastDeviation), units: .celsius)) away. Worth checking airflow, the filter, and whether a door or window is open.")
    }

    /// The room moving the wrong way while the system is on — the loudest
    /// signal there is that something is actually broken.
    private static func wrongDirection(runs: [Run], window: [HVACSample]) -> HVACIssue? {
        for run in runs where run.status.isConditioning && run.minutes >= 30 {
            let inRun = window.filter { $0.date >= run.start && $0.date <= run.end }
            guard let start = inRun.first?.indoorC, let end = inRun.last?.indoorC else { continue }
            let change = end - start
            let wrongWay = run.status == .cooling ? change >= 0.5 : change <= -0.5
            guard wrongWay else { continue }
            return HVACIssue(id: "wrong-direction", severity: .critical,
                             title: run.status == .cooling
                                ? "Cooling, but the room is warming"
                                : "Heating, but the room is cooling",
                             detail: "The system reported \(run.status.displayName.lowercased()) for \(minutes(run.minutes)) while the temperature moved \(SBTemperature.delta(abs(change), units: .celsius)) the other way. That usually means it is moving air but not conditioning it — a frozen coil, low refrigerant, a pilot or ignition fault, or an outdoor unit that is not running.")
        }
        return nil
    }

    private static func runningConstantly(diagnostics: HVACDiagnostics,
                                          spannedHours: Double) -> HVACIssue? {
        guard spannedHours >= 3, diagnostics.runtimeFraction >= 0.85 else { return nil }
        return HVACIssue(id: "constant-runtime", severity: .notice,
                         title: "Running almost constantly",
                         detail: "\(percent(diagnostics.runtimeFraction)) of the last \(hours(spannedHours)). That is normal in extreme weather, and a sign of an undersized or struggling system otherwise.")
    }

    /// Air conditioning that cycles too fast never pulls moisture out, so
    /// high humidity while cooling is worth pairing with the cycling check.
    private static func humidityWhileCooling(window: [HVACSample]) -> HVACIssue? {
        let cooling = window.filter { $0.status == .cooling }
        guard cooling.count >= 6 else { return nil }
        let humidities = cooling.compactMap(\.humidity)
        guard humidities.count >= 6 else { return nil }
        let mean = humidities.reduce(0, +) / Double(humidities.count)
        guard mean >= 65 else { return nil }
        return HVACIssue(id: "humid-while-cooling", severity: .notice,
                         title: "Cool but humid",
                         detail: "Indoor humidity averaged \(Int(mean.rounded()))% while the air conditioning ran. Cooling only dehumidifies once it has run a while, so this often travels with short cycling.")
    }

    /// A room that swings widely between cycles is usually a thermostat in a
    /// bad spot, or a system that overshoots.
    private static func wideSwing(window: [HVACSample],
                                  diagnostics: HVACDiagnostics) -> HVACIssue? {
        let temperatures = window.compactMap(\.indoorC)
        guard temperatures.count >= 12,
              let low = temperatures.min(), let high = temperatures.max() else { return nil }
        let swing = high - low
        guard swing >= 2.5 else { return nil }
        // A setpoint that moved (a schedule, someone turning it up) explains
        // the swing on its own, and is not a fault.
        let setpoints = window.compactMap(\.targetC)
        if let setLow = setpoints.min(), let setHigh = setpoints.max(), setHigh - setLow >= 1 {
            return nil
        }
        return HVACIssue(id: "wide-swing", severity: .info,
                         title: "Wide temperature swing",
                         detail: "The room moved \(SBTemperature.delta(swing, units: .celsius)) over \(hours(diagnostics.windowHours)) with the setpoint held steady. A degree or two is normal; more than that often means the thermostat is somewhere unrepresentative — over a vent, in sunlight, or on an outside wall.")
    }

    // MARK: - Helpers

    private static func deviation(_ sample: HVACSample?) -> Double? {
        guard let sample, let indoor = sample.indoorC, let target = sample.targetC else {
            return nil
        }
        return indoor - target
    }

    static func maxDeviation(_ samples: [HVACSample]) -> Double? {
        samples.compactMap { deviation($0).map(abs) }.max()
    }

    /// Median rather than mean: one long gap where the app was asleep would
    /// otherwise claim the whole history is coarse.
    static func medianGapMinutes(_ samples: [HVACSample]) -> Double {
        guard samples.count >= 2 else { return 0 }
        let gaps = zip(samples.dropFirst(), samples)
            .map { $0.date.timeIntervalSince($1.date) / 60 }
            .sorted()
        return gaps[gaps.count / 2]
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func minutes(_ value: Double) -> String {
        if value < 1 { return "under a minute" }
        if value < 90 { return "\(Int(value.rounded())) min" }
        return hours(value / 60)
    }

    static func hours(_ value: Double) -> String {
        if value < 1.5 { return "\(Int((value * 60).rounded())) min" }
        if value < 10 { return String(format: "%.1f h", value) }
        return "\(Int(value.rounded())) h"
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
