import Foundation

/// A field turned into something displayable: a label, a value, an optional
/// second line, and a semantic tone.
///
/// This deliberately lives outside SwiftUI. The panel view, the VoiceOver
/// summary and the widget all need the same sentence — "83%, charging at
/// 11 kW" — and computing it in three places is how they drift apart.
public struct TessieStat: Hashable, Sendable, Identifiable {
    public enum Tone: Hashable, Sendable {
        case neutral
        case accent
        case good
        case warn
        case bad
    }

    public var field: TessieField
    public var label: String
    public var value: String
    public var detail: String?
    public var tone: Tone
    /// 0–1, for fields that read as a fill (battery, charge, tire wear).
    public var fraction: Double?

    public var id: String { field.rawValue }

    public init(field: TessieField, label: String, value: String,
                detail: String? = nil, tone: Tone = .neutral, fraction: Double? = nil) {
        self.field = field
        self.label = label
        self.value = value
        self.detail = detail
        self.tone = tone
        self.fraction = fraction
    }
}

/// Turns a vehicle plus a field into a `TessieStat`.
public enum TessieReadout {

    /// The stats to show, in order, for the context the panel is in. Fields
    /// with nothing to say are dropped rather than shown blank — an empty
    /// "Navigation —" tile is worse than no tile.
    public static func stats(for vehicle: TessieVehicle,
                             fields: [TessieField]) -> [TessieStat] {
        fields.compactMap { stat(for: $0, vehicle: vehicle) }
    }

    /// The context a panel should render in, honouring a pinned override.
    public static func context(for vehicle: TessieVehicle?,
                               settings: PanelSettings) -> TessieContext {
        guard settings.tessieAutoContext else { return settings.tessieContext }
        guard let vehicle else { return settings.tessieContext }
        return vehicle.isDriving ? .driving : .parked
    }

    public static func fields(for context: TessieContext,
                              settings: PanelSettings) -> [TessieField] {
        switch context {
        case .parked: return settings.tessieParkedFields
        case .driving: return settings.tessieDrivingFields
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func stat(for field: TessieField, vehicle: TessieVehicle) -> TessieStat? {
        let units = vehicle.units

        switch field {
        case .battery:
            guard let level = vehicle.battery.level else { return nil }
            var detail: String?
            if let limit = vehicle.battery.chargeLimit {
                detail = "limit \(percent(limit))"
            }
            if vehicle.isCharging, let power = vehicle.battery.powerKW, power > 0 {
                detail = "+\(number(power, decimals: 0)) kW"
            }
            return TessieStat(field: field, label: "Battery", value: percent(level),
                              detail: detail, tone: batteryTone(level),
                              fraction: level / 100)

        case .range:
            guard let miles = vehicle.battery.rangeMiles else { return nil }
            return TessieStat(field: field, label: "Range",
                              value: distance(miles, units: units),
                              detail: vehicle.battery.level.map { "at \(percent($0))" },
                              tone: .neutral)

        case .charging:
            let state = vehicle.battery.state
            switch state {
            case .charging, .starting:
                let power = vehicle.battery.powerKW.map { "\(number($0, decimals: 1)) kW" }
                var detail = power
                if let added = vehicle.battery.energyAddedKWh, added > 0 {
                    let addedText = "\(number(added, decimals: 1)) kWh added"
                    detail = detail.map { "\($0) · \(addedText)" } ?? addedText
                }
                return TessieStat(field: field, label: "Charging",
                                  value: vehicle.battery.isFastCharging ? "Supercharging" : "Charging",
                                  detail: detail, tone: .good)
            case .complete:
                return TessieStat(field: field, label: "Charging", value: "Charged",
                                  detail: vehicle.battery.chargeLimit.map { "to \(percent($0))" },
                                  tone: .good)
            case .disconnected, .unknown:
                guard vehicle.battery.state == .disconnected else { return nil }
                return TessieStat(field: field, label: "Charging", value: "Unplugged",
                                  tone: .neutral)
            case .stopped, .noPower:
                return TessieStat(field: field, label: "Charging", value: state.displayName,
                                  detail: "plugged in, not charging", tone: .warn)
            }

        case .chargeComplete:
            guard let done = vehicle.battery.chargeComplete(from: vehicle.capturedAt) else {
                return nil
            }
            return TessieStat(field: field, label: "Charged By", value: clock(done),
                              detail: vehicle.battery.minutesToFull.map { duration(minutes: $0) },
                              tone: .accent)

        case .speed:
            // A stationary car reports no speed at all; showing "0" is more
            // honest than an empty tile once it's actually rolling.
            let mph = vehicle.drive.speedMPH ?? (vehicle.isDriving ? 0 : nil)
            guard let mph else { return nil }
            var detail: String?
            var tone = TessieStat.Tone.accent
            if let posted = vehicle.drive.postedLimitMPH {
                detail = "limit \(speed(posted, units: units))"
                if let over = vehicle.drive.overLimitMPH {
                    tone = over >= 10 ? .bad : .warn
                    detail = "\(speed(posted, units: units)) limit · +\(speed(over, units: units))"
                } else {
                    tone = .good
                }
            } else if let governor = vehicle.drive.governorLimitMPH {
                detail = "capped at \(speed(governor, units: units))"
            }
            return TessieStat(field: field, label: "Speed",
                              value: speed(mph, units: units), detail: detail, tone: tone)

        case .gear:
            guard vehicle.drive.gear != .unknown else { return nil }
            return TessieStat(field: field, label: "Gear",
                              value: vehicle.drive.gear.displayName,
                              tone: vehicle.drive.gear == .park ? .neutral : .accent)

        case .map:
            // The map renders as its own block; this exists so VoiceOver and
            // the widget still have something to say about it.
            guard vehicle.place.hasCoordinate else { return nil }
            return TessieStat(field: field, label: "Map",
                              value: vehicle.place.shortDescription ?? "On the map",
                              tone: .neutral)

        case .location:
            guard let place = vehicle.place.shortDescription else { return nil }
            let detail = vehicle.place.savedLocation.flatMap { saved -> String? in
                guard !saved.isEmpty, let address = vehicle.place.address,
                      !address.isEmpty else { return nil }
                return address.split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
            return TessieStat(field: field, label: "Parked At", value: place,
                              detail: detail, tone: .neutral)

        case .navigation:
            guard let route = vehicle.route,
                  let destination = route.destination, !destination.isEmpty else { return nil }
            var parts: [String] = []
            if let miles = route.milesToArrival { parts.append(distance(miles, units: units)) }
            if let minutes = route.minutesToArrival { parts.append(duration(minutes: minutes)) }
            var tone = TessieStat.Tone.accent
            if let delay = route.trafficDelayMinutes, delay >= 1 {
                parts.append("+\(duration(minutes: delay)) traffic")
                tone = delay >= 10 ? .bad : .warn
            }
            return TessieStat(field: field, label: "Navigating To", value: destination,
                              detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                              tone: tone)

        case .arrival:
            guard let route = vehicle.route,
                  let arrival = route.arrival(from: vehicle.capturedAt) else { return nil }
            var detail: String?
            if let energy = route.energyAtArrival {
                detail = "\(percent(energy)) on arrival"
            }
            return TessieStat(field: field, label: "Arrives", value: clock(arrival),
                              detail: detail,
                              tone: (route.energyAtArrival ?? 100) < 10 ? .warn : .accent)

        case .lock:
            guard let locked = vehicle.security.isLocked else { return nil }
            return TessieStat(field: field, label: "Locked",
                              value: locked ? "Locked" : "Unlocked",
                              detail: vehicle.security.valetMode ? "valet mode" : nil,
                              tone: locked ? .good : .bad)

        case .sentry:
            guard let sentry = vehicle.security.sentryMode else {
                return vehicle.security.sentryAvailable
                    ? TessieStat(field: field, label: "Sentry", value: "Off", tone: .neutral)
                    : nil
            }
            return TessieStat(field: field, label: "Sentry",
                              value: sentry ? "Watching" : "Off",
                              tone: sentry ? .good : .neutral)

        case .openings:
            let open = vehicle.security.openings + vehicle.security.openWindows.map { "\($0) window" }
            if open.isEmpty {
                return TessieStat(field: field, label: "Doors", value: "All closed", tone: .good)
            }
            return TessieStat(field: field, label: "Open",
                              value: open.count == 1 ? open[0] : "\(open.count) open",
                              detail: open.count == 1 ? nil : open.joined(separator: ", "),
                              tone: .warn)

        case .climate:
            guard vehicle.climate.isOn || vehicle.climate.isPreconditioning
                    || vehicle.climate.insideC != nil else { return nil }
            let value: String
            var tone = TessieStat.Tone.neutral
            if vehicle.climate.isPreconditioning {
                value = "Preconditioning"
                tone = .accent
            } else if vehicle.climate.isOn {
                value = "On"
                tone = .accent
            } else {
                value = "Off"
            }
            return TessieStat(field: field, label: "Climate", value: value,
                              detail: vehicle.climate.insideC.map {
                                  "cabin \(temperature($0, units: units))"
                              },
                              tone: tone)

        case .insideTemp:
            guard let inside = vehicle.climate.insideC else { return nil }
            return TessieStat(field: field, label: "Inside",
                              value: temperature(inside, units: units),
                              tone: inside >= 45 ? .bad : .neutral)

        case .outsideTemp:
            guard let outside = vehicle.climate.outsideC else { return nil }
            return TessieStat(field: field, label: "Outside",
                              value: temperature(outside, units: units), tone: .neutral)

        case .odometer:
            guard let miles = vehicle.drive.odometerMiles else { return nil }
            return TessieStat(field: field, label: "Odometer",
                              value: distance(miles, units: units, decimals: 0), tone: .neutral)

        case .tires:
            guard !vehicle.system.tires.isEmpty else { return nil }
            let readings = vehicle.system.tires.map { tire -> String in
                units.metricDistance
                    ? "\(tire.position) \(number(tire.bar, decimals: 1))"
                    : "\(tire.position) \(number(tire.psi, decimals: 0))"
            }
            let lowest = vehicle.system.tires.min { $0.bar < $1.bar }
            let unit = units.metricDistance ? "bar" : "psi"
            return TessieStat(field: field, label: "Tires",
                              value: readings.joined(separator: "  "),
                              detail: unit,
                              // Below ~2.5 bar (36 psi) is soft for a Tesla.
                              tone: (lowest?.bar ?? 3) < 2.5 ? .warn : .good)

        case .driverAssist:
            guard let name = vehicle.system.driverAssistName else { return nil }
            // Deliberately capability, not engagement: Tessie's REST API has
            // no live Autopilot/FSD state, and inventing one would be a lie
            // told at 60 mph.
            var detail = "hardware"
            if vehicle.system.smartSummonAvailable { detail = "hardware · Smart Summon ready" }
            return TessieStat(field: field, label: "Autopilot", value: name,
                              detail: detail, tone: .neutral)

        case .software:
            guard let version = vehicle.system.softwareVersion, !version.isEmpty else { return nil }
            // Tesla appends a build hash to the version; the version alone is
            // what anyone actually recognises.
            let short = version.split(separator: " ").first.map(String.init) ?? version
            if vehicle.system.hasPendingUpdate {
                var detail = vehicle.system.updateVersion.map { "\($0) ready" } ?? "update ready"
                if let progress = vehicle.system.updateDownloadPercent, progress > 0, progress < 100 {
                    detail = "downloading \(percent(progress))"
                }
                return TessieStat(field: field, label: "Software", value: short,
                                  detail: detail, tone: .accent)
            }
            return TessieStat(field: field, label: "Software", value: short, tone: .neutral)

        case .connection:
            return TessieStat(field: field, label: "Connection",
                              value: vehicle.connection.displayName,
                              tone: vehicle.connection == .online ? .good : .neutral)
        }
    }

    /// One line describing the whole vehicle — the VoiceOver label and the
    /// accessory-widget string.
    public static func summary(for vehicle: TessieVehicle, settings: PanelSettings) -> String {
        let context = context(for: vehicle, settings: settings)
        let stats = stats(for: vehicle, fields: fields(for: context, settings: settings))
        guard !stats.isEmpty else {
            return "\(vehicle.name), \(vehicle.connection.displayName.lowercased())"
        }
        let spoken = stats.prefix(4).map { stat -> String in
            stat.detail.map { "\(stat.label) \(stat.value), \($0)" } ?? "\(stat.label) \(stat.value)"
        }
        return "\(vehicle.name). " + spoken.joined(separator: ". ")
    }

    // MARK: - Formatting

    static func batteryTone(_ level: Double) -> TessieStat.Tone {
        switch level {
        case ..<15: return .bad
        case ..<30: return .warn
        default: return .good
        }
    }

    // Public because the widget extension formats the same values for the
    // Lock Screen and must not invent its own rounding.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func number(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic))
    }

    public static func distance(_ miles: Double, units: TessieVehicle.Units,
                                decimals: Int = 0) -> String {
        units.metricDistance
            ? "\(number(miles * 1.609344, decimals: decimals)) km"
            : "\(number(miles, decimals: decimals)) mi"
    }

    public static func speed(_ mph: Double, units: TessieVehicle.Units) -> String {
        units.metricDistance
            ? "\(number(mph * 1.609344, decimals: 0)) km/h"
            : "\(number(mph, decimals: 0)) mph"
    }

    public static func temperature(_ celsius: Double, units: TessieVehicle.Units) -> String {
        units.fahrenheit
            ? "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
            : "\(Int(celsius.rounded()))°C"
    }

    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(max(total, 1)) min" }
        let hours = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
