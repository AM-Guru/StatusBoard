import SwiftUI

// MARK: - Shared formatting

/// Date formatting shared by every clock face. Clocks re-render once a second,
/// often several to a board, so the formatters are made once and kept.
@MainActor
enum ClockText {
    private static var formatters: [String: DateFormatter] = [:]

    static func string(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let key = format + "|" + timeZone.identifier
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }
}

extension PanelSettings {
    var clockTimeZone: TimeZone {
        timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    var clockIsTwentyFourHour: Bool {
        clockHourFormat.isTwentyFourHour()
    }

    /// The place the sun faces report on, when one has been set.
    var solarCoordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    /// The sun's day at this panel's place and time zone, or nil when no
    /// location has been chosen.
    func solarDay(at date: Date) -> SolarDay? {
        guard let place = solarCoordinate else { return nil }
        return SolarCalculator.day(containing: date, latitude: place.latitude,
                                   longitude: place.longitude, timeZone: clockTimeZone)
    }

    /// `padded` only affects a 12-hour clock, where "02:17 PM" reads worse
    /// than "2:17 PM" everywhere except a flip board, whose cards need two
    /// digits to fill.
    @MainActor
    func clockTimeString(_ date: Date, includeSeconds: Bool, padded: Bool = false) -> String {
        let hour = clockIsTwentyFourHour ? "HH" : (padded ? "hh" : "h")
        let format = hour + (includeSeconds ? ":mm:ss" : ":mm")
        return ClockText.string(date, format: format, timeZone: clockTimeZone)
    }

    /// "AM" / "PM" in the device's language, or nil on a 24-hour clock.
    @MainActor
    func clockMeridiem(_ date: Date) -> String? {
        guard !clockIsTwentyFourHour else { return nil }
        return ClockText.string(date, format: "a", timeZone: clockTimeZone)
    }

    @MainActor
    func clockDateString(_ date: Date, includeZone: Bool = true) -> String {
        var text = ClockText.string(date, format: "EEE d MMM", timeZone: clockTimeZone).uppercased()
        if includeZone, let zoneID = timeZoneID, zoneID != TimeZone.current.identifier {
            text += "  ·  " + (clockTimeZone.abbreviation() ?? zoneID)
        }
        return text
    }

    /// A short "5:42 AM" for sunrise and sunset labels.
    @MainActor
    func clockShortTime(_ date: Date) -> String {
        ClockText.string(date, format: clockIsTwentyFourHour ? "HH:mm" : "h:mm a",
                         timeZone: clockTimeZone)
    }
}

/// "13h 42m" / "48m" — durations as a person would say them.
func clockDurationText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = total % 3600 / 60
    if hours == 0 { return "\(minutes)m" }
    return "\(hours)h \(minutes)m"
}

// MARK: - LCD

/// The classic Status Board clock: big LCD digits over a date line.
struct LCDClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(settings.clockTimeString(date, includeSeconds: settings.showsSeconds))
                        .font(SBTheme.lcdFont(size: min(proxy.size.height * 0.52,
                                                        proxy.size.width * 0.16)))
                        .foregroundStyle(accent)
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    if let meridiem = settings.clockMeridiem(date) {
                        Text(meridiem)
                            .font(SBTheme.titleFont(size: min(proxy.size.height * 0.16, 16)))
                            .foregroundStyle(accent.opacity(0.75))
                    }
                }
                if settings.showsClockDate {
                    Text(settings.clockDateString(date))
                        .font(SBTheme.titleFont(size: min(proxy.size.height * 0.14, 15)))
                        .foregroundStyle(sbStyle.textSecondary)
                        .kerning(1.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(6)
    }
}

// MARK: - Flip board

/// A split-flap board: every digit on its own hinged card, the new one
/// dropping over the old.
struct FlipClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        GeometryReader { proxy in
            let time = settings.clockTimeString(date, includeSeconds: false, padded: true)
            let parts = time.split(separator: ":").map(String.init)
            let hours = parts.first ?? "00"
            let minutes = parts.count > 1 ? parts[1] : "00"
            // Cards are sized off the space available so a 2×1 panel and a
            // full-width one both fill their room: six slots wide with
            // seconds, four without, plus the separator — and a slot more for
            // AM/PM, which otherwise wraps off the end of a small panel.
            let meridiem = settings.clockMeridiem(date)
            let slots = (settings.showsSeconds ? 6.5 : 4.5) + (meridiem == nil ? 0 : 1.2)
            let cardWidth = min(proxy.size.width / slots, proxy.size.height * 0.72)
            let cardHeight = min(cardWidth * 1.38, proxy.size.height * (settings.showsClockDate ? 0.78 : 1))

            VStack(spacing: cardHeight * 0.1) {
                HStack(alignment: .center, spacing: cardWidth * 0.09) {
                    group(hours, width: cardWidth, height: cardHeight)
                    separator(height: cardHeight)
                    group(minutes, width: cardWidth, height: cardHeight)
                    if settings.showsSeconds {
                        let seconds = ClockText.string(date, format: "ss",
                                                       timeZone: settings.clockTimeZone)
                        separator(height: cardHeight)
                        group(seconds, width: cardWidth * 0.72, height: cardHeight * 0.72)
                    }
                    if let meridiem {
                        Text(meridiem)
                            .font(SBTheme.titleFont(size: max(8, cardHeight * 0.2)))
                            .foregroundStyle(sbStyle.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if settings.showsClockDate {
                    Text(settings.clockDateString(date))
                        .font(SBTheme.titleFont(size: max(8, min(cardHeight * 0.2, 14))))
                        .foregroundStyle(sbStyle.textSecondary)
                        .kerning(1.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(6)
    }

    private func group(_ text: String, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: width * 0.09) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                FlipCard(character: String(character), width: width, height: height,
                         accent: accent)
            }
        }
    }

    private func separator(height: CGFloat) -> some View {
        VStack(spacing: height * 0.16) {
            ForEach(0..<2, id: \.self) { _ in
                Circle()
                    .fill(accent.opacity(0.8))
                    .frame(width: max(2, height * 0.07), height: max(2, height * 0.07))
            }
        }
    }
}

/// One flap. The card stays put; only the character changes, dropping in from
/// the top as the outgoing one falls away.
private struct FlipCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStaticRender) private var isStaticRender
    let character: String
    let width: CGFloat
    let height: CGFloat
    let accent: Color

    private var animates: Bool { !reduceMotion && !isStaticRender }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.14, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x22262E), Color(hex: 0x101318)],
                                     startPoint: .top, endPoint: .bottom))
            Text(character)
                .font(.system(size: height * 0.68, weight: .semibold, design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(accent)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .id(character)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .move(edge: .bottom).combined(with: .opacity)))
            // The hinge: a dark seam with a hairline of light under it, which
            // is what makes a flat rectangle read as two flaps.
            VStack(spacing: 0) {
                Rectangle().fill(.clear)
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(height: max(1, height * 0.02))
                Rectangle().fill(.clear)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.14, style: .continuous))
        .animation(animates ? .easeOut(duration: 0.26) : nil, value: character)
    }
}

// MARK: - Analog

/// Hands on a tick dial, sized to whatever space the panel has.
struct AnalogClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 - 2
                guard radius > 6 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                draw(in: &context, center: center, radius: radius)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if settings.showsClockDate {
                Text(settings.clockDateString(date))
                    .font(SBTheme.titleFont(size: 10))
                    .foregroundStyle(sbStyle.textSecondary)
                    .kerning(1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(6)
    }

    private func draw(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let components = ClockAngles(date: date, timeZone: settings.clockTimeZone)

        context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(sbStyle.separator), lineWidth: 1)

        // Ticks: every minute, with the hours drawn longer and brighter.
        for tick in 0..<60 {
            let isHour = tick % 5 == 0
            let outer = radius * 0.97
            let inner = radius * (isHour ? 0.84 : 0.91)
            let path = Path { path in
                path.move(to: point(center: center, radius: inner, turns: Double(tick) / 60))
                path.addLine(to: point(center: center, radius: outer, turns: Double(tick) / 60))
            }
            context.stroke(path,
                           with: .color(isHour ? sbStyle.textPrimary.opacity(0.85)
                                              : sbStyle.textSecondary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: isHour ? max(1.5, radius * 0.025)
                                                               : max(0.5, radius * 0.012),
                                              lineCap: .round))
        }

        hand(in: &context, center: center, length: radius * 0.52, turns: components.hourTurns,
             width: max(2.5, radius * 0.075), color: sbStyle.textPrimary)
        hand(in: &context, center: center, length: radius * 0.76, turns: components.minuteTurns,
             width: max(2, radius * 0.05), color: sbStyle.textPrimary)
        if settings.showsSeconds {
            hand(in: &context, center: center, length: radius * 0.84,
                 turns: components.secondTurns, width: max(1, radius * 0.02), color: accent,
                 tailLength: radius * 0.2)
        }

        let pin = radius * 0.06
        context.fill(Path(ellipseIn: CGRect(x: center.x - pin, y: center.y - pin,
                                            width: pin * 2, height: pin * 2)),
                     with: .color(accent))
    }

    private func hand(in context: inout GraphicsContext, center: CGPoint, length: CGFloat,
                      turns: Double, width: CGFloat, color: Color, tailLength: CGFloat = 0) {
        let path = Path { path in
            path.move(to: point(center: center, radius: -tailLength, turns: turns))
            path.addLine(to: point(center: center, radius: length, turns: turns))
        }
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

/// A point `radius` from `center`, `turns` of a full circle clockwise from
/// twelve o'clock. Shared by every round face.
func point(center: CGPoint, radius: CGFloat, turns: Double) -> CGPoint {
    let angle = turns * 2 * .pi - .pi / 2
    return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
}

/// Where the hands point, as fractions of a full turn.
struct ClockAngles {
    let hourTurns: Double
    let minuteTurns: Double
    let secondTurns: Double
    /// Fraction of the whole day elapsed, for the 24-hour faces.
    let dayTurns: Double

    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        secondTurns = second / 60
        minuteTurns = (minute + second / 60) / 60
        hourTurns = (hour.truncatingRemainder(dividingBy: 12) + minute / 60) / 12
        dayTurns = (hour + minute / 60 + second / 3600) / 24
    }
}

// MARK: - 24-hour solar dial

/// A whole day on one ring — midnight at the bottom, noon at the top, the
/// night drawn as a wedge and the time in the middle. After the solar watch
/// faces, but square rather than round so it sits in a panel.
struct SolarDialClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    private var solar: SolarDay? {
        settings.showsSunPosition ? settings.solarDay(at: date) : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Canvas { context, size in
                    let radius = min(size.width, size.height) / 2 - 2
                    guard radius > 10 else { return }
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    draw(in: &context, center: center, radius: radius)
                }
                centerStack(side: side)
                    .frame(width: side * 0.56)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(4)
    }

    @ViewBuilder
    private func centerStack(side: CGFloat) -> some View {
        VStack(spacing: side * 0.02) {
            Text(settings.clockTimeString(date, includeSeconds: settings.showsSeconds))
                .font(SBTheme.lcdFont(size: side * (settings.showsSeconds ? 0.15 : 0.19)))
                .foregroundStyle(sbStyle.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            if let caption = sunCaption {
                Text(caption)
                    .font(SBTheme.titleFont(size: max(7, side * 0.055)))
                    .foregroundStyle(accent)
                    .kerning(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else if settings.showsClockDate {
                Text(settings.clockDateString(date, includeZone: false))
                    .font(SBTheme.titleFont(size: max(7, side * 0.055)))
                    .foregroundStyle(sbStyle.textSecondary)
                    .kerning(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    /// "Sunset 20:31" while it is light, "Sunrise 05:48" overnight — the event
    /// the viewer is actually waiting for.
    private var sunCaption: String? {
        guard let solar else { return nil }
        if solar.isPolarDay { return "MIDNIGHT SUN" }
        if solar.isPolarNight { return "POLAR NIGHT" }
        if solar.isDaylight(at: date), let sunset = solar.sunset {
            return "SUNSET " + settings.clockShortTime(sunset)
        }
        guard let place = settings.solarCoordinate,
              let sunrise = SolarCalculator.nextSunrise(after: date, latitude: place.latitude,
                                                        longitude: place.longitude,
                                                        timeZone: settings.clockTimeZone)
        else { return nil }
        return "SUNRISE " + settings.clockShortTime(sunrise)
    }

    private func draw(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let ringWidth = radius * 0.13
        let ringRadius = radius - ringWidth / 2
        let ring = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                          width: ringRadius * 2, height: ringRadius * 2))
        // The night ring first, then daylight laid over the part of the day the
        // sun is actually up.
        context.stroke(ring, with: .color(sbStyle.separator.opacity(sbStyle.isLight ? 0.5 : 0.9)),
                       lineWidth: ringWidth)

        if let solar, !solar.isPolarNight {
            let daylight = daylightTurns(solar)
            let path = Path { path in
                path.addArc(center: center, radius: ringRadius,
                            startAngle: .radians(daylight.start * 2 * .pi - .pi / 2),
                            endAngle: .radians(daylight.end * 2 * .pi - .pi / 2),
                            clockwise: false)
            }
            context.stroke(path, with: .color(accent.opacity(0.85)),
                           style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
        }

        // Hour ticks every hour, with a numeral every four so the ring reads
        // as a day rather than a decoration.
        for hour in 0..<24 {
            let turns = dayTurns(hours: Double(hour))
            let isMajor = hour % 4 == 0
            let path = Path { path in
                path.move(to: point(center: center, radius: radius - ringWidth * 1.15, turns: turns))
                path.addLine(to: point(center: center,
                                       radius: radius - ringWidth * (isMajor ? 1.65 : 1.4),
                                       turns: turns))
            }
            context.stroke(path, with: .color(sbStyle.textSecondary.opacity(isMajor ? 0.9 : 0.4)),
                           style: StrokeStyle(lineWidth: isMajor ? 2 : 1, lineCap: .round))
            if isMajor && radius > 42 {
                let label = Text(String(format: "%02d", hour))
                    .font(SBTheme.titleFont(size: max(7, radius * 0.11)))
                    .foregroundStyle(sbStyle.textSecondary)
                context.draw(label, at: point(center: center,
                                              radius: radius - ringWidth * 2.4, turns: turns))
            }
        }

        if settings.showsClockHands {
            let angles = ClockAngles(date: date, timeZone: settings.clockTimeZone)
            clockHand(in: &context, center: center, radius: radius * 0.42,
                      turns: angles.hourTurns, width: max(2.5, radius * 0.035),
                      color: sbStyle.textPrimary)
            clockHand(in: &context, center: center, radius: radius * 0.62,
                      turns: angles.minuteTurns, width: max(2, radius * 0.025),
                      color: sbStyle.textPrimary)
            if settings.showsSeconds {
                clockHand(in: &context, center: center, radius: radius * 0.72,
                          turns: angles.secondTurns, width: max(1, radius * 0.012),
                          color: accent, tail: radius * 0.12)
            }
            let pin = max(2, radius * 0.035)
            context.fill(Path(ellipseIn: CGRect(x: center.x - pin, y: center.y - pin,
                                                width: pin * 2, height: pin * 2)),
                         with: .color(accent))
        }

        // Where the sun is now.
        let nowTurns = dayTurns(hours: ClockAngles(date: date,
                                                   timeZone: settings.clockTimeZone).dayTurns * 24)
        let markerCenter = point(center: center, radius: ringRadius, turns: nowTurns)
        let markerRadius = ringWidth * 0.62
        context.fill(Path(ellipseIn: CGRect(x: markerCenter.x - markerRadius,
                                            y: markerCenter.y - markerRadius,
                                            width: markerRadius * 2, height: markerRadius * 2)),
                     with: .color(sbStyle.textPrimary))
        context.stroke(Path(ellipseIn: CGRect(x: markerCenter.x - markerRadius,
                                              y: markerCenter.y - markerRadius,
                                              width: markerRadius * 2, height: markerRadius * 2)),
                       with: .color(sbStyle.separator), lineWidth: 1.5)
    }

    /// Midnight at the bottom of the dial, noon at the top.
    private func dayTurns(hours: Double) -> Double {
        (hours / 24 + 0.5).truncatingRemainder(dividingBy: 1)
    }

    private func daylightTurns(_ solar: SolarDay) -> (start: Double, end: Double) {
        guard !solar.isPolarDay, let sunrise = solar.sunrise, let sunset = solar.sunset else {
            return (0, 1)
        }
        return (dayTurns(hours: hourOfDay(sunrise)), dayTurns(hours: hourOfDay(sunset)))
    }

    private func hourOfDay(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.clockTimeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    private func clockHand(in context: inout GraphicsContext, center: CGPoint,
                           radius: CGFloat, turns: Double, width: CGFloat,
                           color: Color, tail: CGFloat = 0) {
        let path = Path { path in
            path.move(to: point(center: center, radius: -tail, turns: turns))
            path.addLine(to: point(center: center, radius: radius, turns: turns))
        }
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - Modular

/// Oversized time with the date and time zone stacked around it, plus a
/// daylight bar when the panel knows where it is — the widget-shaped cousin of
/// the modular watch layouts.
struct ModularClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    private var solar: SolarDay? {
        settings.showsSunPosition ? settings.solarDay(at: date) : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.height, proxy.size.width * 0.42)
            VStack(alignment: .leading, spacing: scale * 0.06) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ClockText.string(date, format: "EEEE", timeZone: settings.clockTimeZone)
                        .uppercased())
                        .font(SBTheme.titleFont(size: max(9, min(scale * 0.16, 15))))
                        .foregroundStyle(accent)
                        .kerning(1.6)
                    Spacer(minLength: 4)
                    Text(zoneLabel)
                        .font(SBTheme.titleFont(size: max(8, min(scale * 0.14, 13))))
                        .foregroundStyle(sbStyle.textSecondary)
                        .kerning(1.2)
                }
                .lineLimit(1)

                HStack(alignment: .lastTextBaseline, spacing: scale * 0.06) {
                    Text(settings.clockTimeString(date, includeSeconds: false))
                        .font(.system(size: scale * 0.52, weight: .semibold, design: .rounded)
                            .monospacedDigit())
                        .foregroundStyle(sbStyle.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    VStack(alignment: .leading, spacing: 0) {
                        if let meridiem = settings.clockMeridiem(date) {
                            Text(meridiem)
                                .font(SBTheme.titleFont(size: max(9, min(scale * 0.17, 18))))
                                .foregroundStyle(sbStyle.textSecondary)
                        }
                        if settings.showsSeconds {
                            Text(ClockText.string(date, format: "ss",
                                                  timeZone: settings.clockTimeZone))
                                .font(SBTheme.lcdFont(size: max(10, min(scale * 0.2, 22))))
                                .foregroundStyle(accent)
                                .contentTransition(.numericText())
                        }
                    }
                }

                if settings.showsClockDate {
                    Text(ClockText.string(date, format: "d MMMM y",
                                          timeZone: settings.clockTimeZone).uppercased())
                        .font(SBTheme.titleFont(size: max(8, min(scale * 0.14, 13))))
                        .foregroundStyle(sbStyle.textSecondary)
                        .kerning(1.2)
                        .lineLimit(1)
                }

                if let solar, proxy.size.height > 70 {
                    DaylightBar(solar: solar, settings: settings, date: date, height: scale * 0.09)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .padding(10)
    }

    private var zoneLabel: String {
        if let zoneID = settings.timeZoneID, zoneID != TimeZone.current.identifier {
            return settings.clockTimeZone.abbreviation() ?? zoneID
        }
        return settings.clockTimeZone.abbreviation() ?? ""
    }
}

// MARK: - Solar

/// The sky as it looks *right now*, from where the sun is relative to the
/// horizon — which is the whole difference between midday, the golden hour, a
/// sunset, civil dusk, deep twilight and night.
///
/// Three colors rather than one: the sky is not flat. The horizon takes the
/// sun's color, the zenith stays the deep blue of the atmosphere seen
/// end-on, and the middle carries the transition — which is what makes a
/// sunset read as a sunset rather than as an orange wash.
struct SBSkyScene {
    let horizon: Color
    let middle: Color
    let zenith: Color
    /// Just under the horizon, and further down.
    let groundNear: Color
    let groundFar: Color
    /// The halo around the sun, and how much of it there is.
    let glow: Color
    let glowStrength: Double
    /// Dark enough that the moon is the thing worth looking at.
    let isNight: Bool

    /// altitude° → horizon, middle, zenith. Read from the top down; the sun
    /// walks these stops as it rises and sets.
    private static let stops: [(Double, UInt32, UInt32, UInt32)] = [
        (60, 0xCFE4F7, 0x5AA0E8, 0x11408C),   // overhead
        (20, 0xD3E5F6, 0x62A8E8, 0x1B57AE),
        (8, 0xEBD9C0, 0x88B6E4, 0x275FA8),    // the light going long
        (3, 0xF6B778, 0xA793C4, 0x2E4E92),    // golden hour
        (0, 0xF0873C, 0xC06E86, 0x35407C),    // sunrise / sunset
        (-3, 0xE05C3F, 0x9A4C79, 0x2A3570),
        (-6, 0xB03F63, 0x6B3B78, 0x1F2A5E),   // end of civil twilight
        (-9, 0x74305F, 0x462D66, 0x17204C),
        (-12, 0x3C2857, 0x25204A, 0x101838),  // end of nautical twilight
        (-15, 0x241D45, 0x161636, 0x0C1128),
        (-18, 0x141232, 0x0D0D24, 0x070A18),  // end of astronomical twilight
        (-25, 0x0A0A1C, 0x070812, 0x04050C),  // night proper
    ]

    /// altitude° → how strong the sun's halo is. Brightest just as it touches
    /// the horizon, gone once it is properly down.
    private static let glowStops: [(Double, Double)] = [
        (30, 0.42), (8, 0.55), (0, 0.62), (-4, 0.30), (-8, 0.12), (-12, 0)
    ]

    init(sunAltitude: Double) {
        let colors = Self.interpolate(sunAltitude)
        horizon = Color(hex: colors.0)
        middle = Color(hex: colors.1)
        zenith = Color(hex: colors.2)
        // The ground is the same light with most of it taken away — it keeps
        // the sunset's color in the land instead of going flatly black. Mixed
        // toward the zenith first, or a pale midday horizon would leave the
        // land grey rather than the deep blue an unlit landscape actually is.
        let landLight = SBSkyScene.mix(colors.0, colors.2, 0.55)
        groundNear = Color(hex: SBSkyScene.darken(landLight, by: 0.62))
        groundFar = Color(hex: SBSkyScene.darken(colors.2, by: 0.82))
        glowStrength = Self.interpolateGlow(sunAltitude)
        glow = sunAltitude > 2
            ? Color(.sRGB, red: 1, green: 0.97, blue: 0.90, opacity: 1)
            : Color(.sRGB, red: 1, green: 0.72, blue: 0.42, opacity: 1)
        isNight = sunAltitude < -6
    }

    private static func interpolate(_ altitude: Double) -> (UInt32, UInt32, UInt32) {
        if altitude >= stops[0].0 { return (stops[0].1, stops[0].2, stops[0].3) }
        let last = stops[stops.count - 1]
        if altitude <= last.0 { return (last.1, last.2, last.3) }
        for index in 1..<stops.count where altitude > stops[index].0 {
            let upper = stops[index - 1]
            let lower = stops[index]
            let t = (altitude - lower.0) / (upper.0 - lower.0)
            return (mix(lower.1, upper.1, t), mix(lower.2, upper.2, t), mix(lower.3, upper.3, t))
        }
        return (last.1, last.2, last.3)
    }

    private static func interpolateGlow(_ altitude: Double) -> Double {
        if altitude >= glowStops[0].0 { return glowStops[0].1 }
        let last = glowStops[glowStops.count - 1]
        if altitude <= last.0 { return last.1 }
        for index in 1..<glowStops.count where altitude > glowStops[index].0 {
            let upper = glowStops[index - 1]
            let lower = glowStops[index]
            let t = (altitude - lower.0) / (upper.0 - lower.0)
            return lower.1 + (upper.1 - lower.1) * t
        }
        return last.1
    }

    private static func mix(_ from: UInt32, _ to: UInt32, _ t: Double) -> UInt32 {
        var result: UInt32 = 0
        for shift in [16, 8, 0] {
            let a = Double((from >> UInt32(shift)) & 0xFF)
            let b = Double((to >> UInt32(shift)) & 0xFF)
            let value = UInt32((a + (b - a) * min(1, max(0, t))).rounded())
            result |= value << UInt32(shift)
        }
        return result
    }

    private static func darken(_ color: UInt32, by amount: Double) -> UInt32 {
        mix(color, 0x000000, amount)
    }
}

/// The solar dial: a 24-hour clock whose sky is split by the horizon, with
/// midnight at the bottom, noon at the top and the sun riding the ring.
///
/// The horizon is the *chord* joining sunrise to sunset on the dial, which is
/// what makes the whole thing turn through the year: a long summer day pushes
/// the chord down and opens the sky up, a winter one lifts it until only a
/// sliver of daylight is left, and the equinoxes lay it flat across the middle.
/// Nothing is decorative — the sun sits at the current hour, so it crosses the
/// horizon exactly at sunrise and sunset.
///
/// Unlike a watch face it fills a rectangle: the sky runs to all four edges and
/// the corners carry the day's numbers, the way complications sit around a dial.
struct SolarClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        guard let place = settings.solarCoordinate else {
            return AnyView(ErrorView(message: "Set this panel's location to draw the sun's dial"))
        }
        return AnyView(content(place: place))
    }

    private func content(place: (latitude: Double, longitude: Double)) -> some View {
        let solar = SolarCalculator.day(containing: date, latitude: place.latitude,
                                        longitude: place.longitude,
                                        timeZone: settings.clockTimeZone)
        let altitude = SolarCalculator.altitude(at: date, latitude: place.latitude,
                                                longitude: place.longitude)
        let moon = MoonCalculator.position(at: date, latitude: place.latitude,
                                           longitude: place.longitude)
        return GeometryReader { proxy in
            let radius = dialRadius(in: proxy.size)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Canvas { context, size in
                    draw(in: &context, size: size, center: center, radius: radius,
                         solar: solar, altitude: altitude, moon: moon)
                }
                centerReadout(radius: radius)
                    .frame(width: radius * 1.5)
                    .position(center)
                corners(size: proxy.size, radius: radius, solar: solar, moon: moon)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // No padding: the sky is the panel, the way a widget fills its tile.
    }

    /// The dial leaves room for the corner readouts on a wide panel and simply
    /// fits the height on a narrow one.
    private func dialRadius(in size: CGSize) -> CGFloat {
        let fits = min(size.width, size.height) / 2 - 6
        guard hasCorners(size) else { return max(20, fits) }
        return max(20, min(fits, size.height / 2 - 8))
    }

    private func hasCorners(_ size: CGSize) -> Bool {
        size.width > size.height * 1.45 && size.height > 90
    }

    // MARK: Readouts

    private func centerReadout(radius: CGFloat) -> some View {
        VStack(spacing: 1) {
            Text(settings.clockTimeString(date, includeSeconds: settings.showsSeconds))
                .font(.system(size: radius * (settings.showsSeconds ? 0.32 : 0.42),
                              weight: .medium, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            if settings.showsClockDate {
                Text(settings.clockDateString(date, includeZone: false))
                    .font(SBTheme.titleFont(size: max(7, radius * 0.12)))
                    .kerning(1.2)
                    .opacity(0.75)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    /// The day's numbers in the corners the dial doesn't reach — sunrise and
    /// sunset on the side each of them happens.
    @ViewBuilder
    private func corners(size: CGSize, radius: CGFloat, solar: SolarDay,
                         moon: MoonPosition) -> some View {
        if hasCorners(size) {
            let scale = min(size.height * 0.5, size.width * 0.12)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    cornerBlock("SUNRISE", solar.sunrise.map(settings.clockShortTime)
                                ?? placeholder(solar), scale: scale, alignment: .leading)
                    Spacer(minLength: 0)
                    cornerBlock(settings.locationName?.uppercased() ?? "DAYLIGHT",
                                daylightText(solar), scale: scale, alignment: .leading)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    cornerBlock("SUNSET", solar.sunset.map(settings.clockShortTime)
                                ?? placeholder(solar), scale: scale, alignment: .trailing)
                    Spacer(minLength: 0)
                    cornerBlock(moon.phaseName.uppercased(),
                                "\(Int((moon.illumination * 100).rounded()))%",
                                scale: scale, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func cornerBlock(_ title: String, _ value: String, scale: CGFloat,
                             alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(title)
                .font(SBTheme.titleFont(size: max(7, min(scale * 0.16, 11))))
                .kerning(1.4)
                .opacity(0.7)
            Text(value)
                .font(SBTheme.lcdFont(size: max(11, min(scale * 0.3, 22))))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private func placeholder(_ solar: SolarDay) -> String {
        solar.isPolarDay || solar.isPolarNight ? "NONE" : "—"
    }

    private func daylightText(_ solar: SolarDay) -> String {
        if solar.isPolarDay { return "ALL DAY" }
        if solar.isPolarNight { return "NONE" }
        return solar.daylight.map(clockDurationText) ?? "—"
    }

    private func altitudeText(_ altitude: Double) -> String {
        let rounded = Int(altitude.rounded())
        return rounded >= 0 ? "+\(rounded)°" : "\(rounded)°"
    }

    // MARK: The dial

    /// Where an instant sits on the dial: midnight at the bottom, noon at the
    /// top, the same way round as a compass.
    private func turns(of moment: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.clockTimeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: moment)
        let hours = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
            + Double(parts.second ?? 0) / 3600
        return (hours / 24 + 0.5).truncatingRemainder(dividingBy: 1)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, center: CGPoint,
                      radius: CGFloat, solar: SolarDay, altitude: Double, moon: MoonPosition) {
        let scene = SBSkyScene(sunAltitude: altitude)
        drawSky(in: &context, size: size, center: center, radius: radius, solar: solar,
                scene: scene)
        drawRing(in: &context, center: center, radius: radius)
        drawOrbit(in: &context, center: center, radius: radius, solar: solar)
        drawMoon(in: &context, center: center, radius: radius, moon: moon)
        drawSun(in: &context, center: center, radius: radius, solar: solar, scene: scene)
        drawCenterDisc(in: &context, center: center, radius: radius)
    }

    /// The sky, split along the sunrise-to-sunset chord and run out to every
    /// edge of the panel — coloured by where the sun is *now*, so the panel is
    /// blue at midday, on fire at sunset and black at two in the morning.
    private func drawSky(in context: inout GraphicsContext, size: CGSize, center: CGPoint,
                         radius: CGFloat, solar: SolarDay, scene: SBSkyScene) {
        let everything = Path(CGRect(origin: .zero, size: size))
        let reach = max(size.width, size.height) * 1.5

        guard let sunrise = solar.sunrise, let sunset = solar.sunset, !solar.isPolarDay,
              !solar.isPolarNight else {
            // Inside the polar circles there is no horizon to cross today, so
            // the sky simply runs from the zenith down.
            context.fill(everything, with: .linearGradient(
                Gradient(colors: [scene.zenith, scene.middle, scene.horizon]),
                startPoint: CGPoint(x: center.x, y: 0),
                endPoint: CGPoint(x: center.x, y: size.height)))
            return
        }

        let rise = point(center: center, radius: radius, turns: turns(of: sunrise))
        let set = point(center: center, radius: radius, turns: turns(of: sunset))
        let along = CGVector(dx: set.x - rise.x, dy: set.y - rise.y)
        let length = max(0.001, sqrt(along.dx * along.dx + along.dy * along.dy))
        let unit = CGVector(dx: along.dx / length, dy: along.dy / length)
        // The normal pointing at noon — the daylight side of the chord.
        var normal = CGVector(dx: unit.dy, dy: -unit.dx)
        let noon = point(center: center, radius: radius, turns: 0)
        let middle = CGPoint(x: (rise.x + set.x) / 2, y: (rise.y + set.y) / 2)
        if normal.dx * (noon.x - middle.x) + normal.dy * (noon.y - middle.y) < 0 {
            normal = CGVector(dx: -normal.dx, dy: -normal.dy)
        }

        func halfPlane(_ direction: CGVector) -> Path {
            Path { path in
                let a = CGPoint(x: middle.x - unit.dx * reach, y: middle.y - unit.dy * reach)
                let b = CGPoint(x: middle.x + unit.dx * reach, y: middle.y + unit.dy * reach)
                path.move(to: a)
                path.addLine(to: b)
                path.addLine(to: CGPoint(x: b.x + direction.dx * reach, y: b.y + direction.dy * reach))
                path.addLine(to: CGPoint(x: a.x + direction.dx * reach, y: a.y + direction.dy * reach))
                path.closeSubpath()
            }
        }

        // How far the panel actually reaches on each side of the horizon. The
        // ramp is scaled to that rather than to the dial, so full night is
        // reached in the corner of the panel instead of somewhere off-screen —
        // otherwise a wide panel shows nothing but the twilight end of it.
        func extent(_ direction: CGVector) -> CGFloat {
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                           CGPoint(x: 0, y: size.height),
                           CGPoint(x: size.width, y: size.height)]
            let far = corners.map { corner in
                direction.dx * (corner.x - middle.x) + direction.dy * (corner.y - middle.y)
            }.max() ?? radius
            return max(radius * 0.6, far)
        }
        let down = CGVector(dx: -normal.dx, dy: -normal.dy)
        let nightReach = extent(down)
        let dayReach = extent(normal)

        // Ground first, then the sky over it — each graded away from the
        // horizon, and both taking their colors from where the sun stands.
        context.fill(everything, with: .color(scene.groundFar))
        context.fill(halfPlane(down), with: .linearGradient(
            Gradient(colors: [scene.groundNear, scene.groundFar]),
            startPoint: middle,
            endPoint: CGPoint(x: middle.x + down.dx * nightReach,
                              y: middle.y + down.dy * nightReach)))
        context.fill(halfPlane(normal), with: .linearGradient(
            Gradient(colors: [scene.horizon, scene.middle, scene.zenith]),
            startPoint: middle,
            endPoint: CGPoint(x: middle.x + normal.dx * dayReach,
                              y: middle.y + normal.dy * dayReach)))

        // The sun's own glow, brightest where it meets the horizon — this is
        // what turns "orange sky" into a sunset happening in one place.
        if scene.glowStrength > 0 {
            let sunPoint = point(center: center, radius: radius, turns: turns(of: date))
            context.fill(everything, with: .radialGradient(
                Gradient(colors: [scene.glow.opacity(scene.glowStrength),
                                  scene.glow.opacity(0)]),
                center: sunPoint, startRadius: 0, endRadius: radius * 0.9))
        }

        // And the horizon itself, drawn as the crisp line the eye looks for.
        context.stroke(Path { path in
            path.move(to: CGPoint(x: middle.x - unit.dx * reach, y: middle.y - unit.dy * reach))
            path.addLine(to: CGPoint(x: middle.x + unit.dx * reach, y: middle.y + unit.dy * reach))
        }, with: .color(.white.opacity(0.35)), lineWidth: 1)
    }

    /// The 24-hour scale: a tick an hour, a numeral every other one.
    private func drawRing(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(.white.opacity(0.25)), lineWidth: 1)
        for hour in 0..<24 {
            let hourTurns = (Double(hour) / 24 + 0.5).truncatingRemainder(dividingBy: 1)
            let major = hour % 2 == 0
            context.stroke(Path { path in
                path.move(to: point(center: center, radius: radius, turns: hourTurns))
                path.addLine(to: point(center: center,
                                       radius: radius - radius * (major ? 0.07 : 0.04),
                                       turns: hourTurns))
            }, with: .color(.white.opacity(major ? 0.75 : 0.4)),
               style: StrokeStyle(lineWidth: major ? 1.6 : 1, lineCap: .round))

            guard major, radius > 54 else { continue }
            let label = Text(String(format: "%02d", hour))
                .font(.system(size: max(8, radius * 0.13), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(hour % 6 == 0 ? 0.95 : 0.6))
            context.draw(label, at: point(center: center, radius: radius * 0.85, turns: hourTurns))
        }
    }

    /// The sun's own track, with the four moments of the day marked on it:
    /// sunrise, noon, sunset, midnight.
    private func drawOrbit(in context: inout GraphicsContext, center: CGPoint,
                           radius: CGFloat, solar: SolarDay) {
        let orbit = radius * 0.72
        context.stroke(Path(ellipseIn: CGRect(x: center.x - orbit, y: center.y - orbit,
                                              width: orbit * 2, height: orbit * 2)),
                       with: .color(.white.opacity(0.22)), lineWidth: 1)
        var marks: [(Date, Bool)] = [(solar.solarNoon, true)]
        if let sunrise = solar.sunrise { marks.append((sunrise, false)) }
        if let sunset = solar.sunset { marks.append((sunset, false)) }
        for (moment, isNoon) in marks {
            let dot = point(center: center, radius: orbit, turns: turns(of: moment))
            let size = isNoon ? radius * 0.035 : radius * 0.028
            context.fill(Path(ellipseIn: CGRect(x: dot.x - size, y: dot.y - size,
                                                width: size * 2, height: size * 2)),
                         with: .color(.white.opacity(isNoon ? 0.9 : 0.7)))
            // A hairline out to the hour scale, so a marker reads as a time.
            context.stroke(Path { path in
                path.move(to: dot)
                path.addLine(to: point(center: center, radius: radius,
                                       turns: turns(of: moment)))
            }, with: .color(.white.opacity(0.18)), lineWidth: 1)
        }
    }

    /// The moon, on the same ring and by the same rule as the sun: it sits at
    /// the hour whose place in the sky it currently occupies. A new moon rides
    /// with the sun, a full moon sits opposite it, a first-quarter moon trails
    /// six hours behind — and the dot is drawn as the phase it is in.
    private func drawMoon(in context: inout GraphicsContext, center: CGPoint,
                          radius: CGFloat, moon: MoonPosition) {
        let moment = date.addingTimeInterval(moon.hoursFromSun * 3600)
        let position = point(center: center, radius: radius, turns: turns(of: moment))
        let sunPosition = point(center: center, radius: radius, turns: turns(of: date))
        let size = max(4, radius * 0.068)
        let isUp = moon.altitude > 0
        // A moon under the horizon is still worth marking — it says when it
        // will be back — but it should not compete with what is on show.
        let opacity = isUp ? 1.0 : 0.5

        if isUp && moon.illumination > 0.15 {
            context.fill(Path(ellipseIn: CGRect(x: position.x - size * 2.4,
                                                y: position.y - size * 2.4,
                                                width: size * 4.8, height: size * 4.8)),
                         with: .color(.white.opacity(0.13 * moon.illumination)))
        }
        let disc = CGRect(x: position.x - size, y: position.y - size,
                          width: size * 2, height: size * 2)
        // The dark limb first, so a crescent still reads as a whole moon
        // rather than as a chip of light floating on the dial.
        context.fill(Path(ellipseIn: disc),
                     with: .color(Color(hex: 0x4B5260).opacity(opacity)))
        context.fill(litPath(center: position, towards: sunPosition, radius: size,
                             illumination: moon.illumination),
                     with: .color(Color(hex: 0xE4E8EE).opacity(opacity)))
        context.stroke(Path(ellipseIn: disc),
                       with: .color(.white.opacity(0.22 * opacity)), lineWidth: 0.75)
    }

    /// The lit part of the moon's disc: the outer limb on the side facing the
    /// sun, closed by the terminator — an ellipse that narrows to a straight
    /// line at the quarters and bows back once the moon is gibbous.
    ///
    /// Turned to face the sun's own place on the dial rather than being drawn
    /// left or right by rule: the bright limb always points at the sun, so on
    /// a dial that carries both, pointing it there *is* the correct answer —
    /// and it comes out right in either hemisphere without asking.
    private func litPath(center: CGPoint, towards sun: CGPoint, radius: CGFloat,
                         illumination: Double) -> Path {
        let terminator = CGFloat(1 - 2 * min(1, max(0, illumination)))
        let steps = 36
        var path = Path()
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * .pi
            let point = CGPoint(x: radius * CGFloat(sin(angle)),
                                y: -radius * CGFloat(cos(angle)))
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for step in stride(from: steps, through: 0, by: -1) {
            let angle = Double(step) / Double(steps) * .pi
            path.addLine(to: CGPoint(x: terminator * radius * CGFloat(sin(angle)),
                                     y: -radius * CGFloat(cos(angle))))
        }
        path.closeSubpath()
        // Built with the lit limb along +x, then turned so +x points at the sun.
        let bearing = atan2(sun.y - center.y, sun.x - center.x)
        return path
            .applying(CGAffineTransform(rotationAngle: bearing))
            .applying(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// The sun on the ring at the hour it is now — above the horizon by day,
    /// under it at night, crossing exactly at sunrise and sunset.
    private func drawSun(in context: inout GraphicsContext, center: CGPoint,
                         radius: CGFloat, solar: SolarDay, scene: SBSkyScene) {
        let position = point(center: center, radius: radius, turns: turns(of: date))
        let isUp = solar.isDaylight(at: date)
        let size = max(4, radius * 0.075)
        let disc = CGRect(x: position.x - size, y: position.y - size,
                          width: size * 2, height: size * 2)
        context.fill(Path(ellipseIn: disc.insetBy(dx: -size * 1.1, dy: -size * 1.1)),
                     with: .color(.white.opacity(isUp ? 0.30 : 0.12)))
        context.fill(Path(ellipseIn: disc),
                     with: .color(isUp ? .white : Color.white.opacity(0.55)))
        if !isUp {
            // At night it is a disc with a hole in it: present, but plainly not
            // the thing lighting the sky. Filled with the ground it is under,
            // so it reads as a hole rather than as a second, darker moon.
            context.fill(Path(ellipseIn: disc.insetBy(dx: size * 0.45, dy: size * 0.45)),
                         with: .color(scene.groundFar))
        }
    }

    /// The face's own inner dial: a translucent disc under the time, ringed by
    /// minute ticks.
    private func drawCenterDisc(in context: inout GraphicsContext, center: CGPoint,
                                radius: CGFloat) {
        let inner = radius * 0.5
        let disc = CGRect(x: center.x - inner, y: center.y - inner,
                          width: inner * 2, height: inner * 2)
        context.fill(Path(ellipseIn: disc), with: .color(.black.opacity(0.28)))
        context.stroke(Path(ellipseIn: disc), with: .color(.white.opacity(0.28)), lineWidth: 1)
        guard radius > 46 else { return }
        for minute in 0..<60 {
            let minuteTurns = Double(minute) / 60
            context.stroke(Path { path in
                path.move(to: point(center: center, radius: inner * 0.97, turns: minuteTurns))
                path.addLine(to: point(center: center,
                                       radius: inner * (minute % 5 == 0 ? 0.86 : 0.91),
                                       turns: minuteTurns))
            }, with: .color(.white.opacity(minute % 5 == 0 ? 0.55 : 0.28)), lineWidth: 1)
        }
    }
}

/// A whole day of sky laid out end to end: local midnight to local midnight
/// left to right, the sun's altitude drawn as the curve through it, and now
/// marked where it falls.
///
/// The flat cousin of `SolarClockFace` — the same day, but with the twilight
/// bands — golden hour, civil, nautical, astronomical — spread wide enough to
/// read individually instead of wrapped around a dial.
struct TwilightBandClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        guard let place = settings.solarCoordinate else {
            return AnyView(ErrorView(message: "Set this panel's location to draw the sun's day"))
        }
        return AnyView(content(place: place))
    }

    private func content(place: (latitude: Double, longitude: Double)) -> some View {
        let solar = SolarCalculator.day(containing: date, latitude: place.latitude,
                                        longitude: place.longitude,
                                        timeZone: settings.clockTimeZone)
        let day = dayStart
        let altitudeNow = SolarCalculator.altitude(at: date, latitude: place.latitude,
                                                   longitude: place.longitude)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(in: &context, size: size, place: place, day: day, solar: solar)
                }
                overlay(size: proxy.size, solar: solar, altitude: altitudeNow)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Deliberately no padding: the sky is the panel, the way a widget
        // fills its own tile.
    }

    private var dayStart: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.clockTimeZone
        return calendar.startOfDay(for: date)
    }

    // MARK: Text over the sky

    /// White over the sky rather than the theme's text color: the band behind
    /// it is a picture of the day, not a themed surface, and it runs from
    /// noon blue to midnight black under the same words.
    private func overlay(size: CGSize, solar: SolarDay, altitude: Double) -> some View {
        let scale = min(size.height, size.width * 0.34)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.clockTimeString(date, includeSeconds: settings.showsSeconds))
                        .font(.system(size: max(18, min(scale * 0.34, 52)),
                                      weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(SBTheme.titleFont(size: max(8, min(scale * 0.12, 13))))
                        .kerning(1.2)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(nextEventText(solar: solar))
                        .font(SBTheme.titleFont(size: max(8, min(scale * 0.13, 14))))
                        .kerning(1)
                    Text(altitudeText(altitude))
                        .font(SBTheme.titleFont(size: max(8, min(scale * 0.12, 13))))
                        .kerning(1)
                        .opacity(0.75)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(.white)
        // The sky behind is bright at noon and black at night, so the text
        // carries its own shadow instead of relying on either.
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var subtitle: String {
        let date = settings.clockDateString(date)
        guard let name = settings.locationName, !name.isEmpty else { return date }
        return name.uppercased() + "  ·  " + date
    }

    private func altitudeText(_ altitude: Double) -> String {
        let rounded = Int(altitude.rounded())
        return rounded >= 0 ? "SUN \(rounded)° UP" : "SUN \(-rounded)° DOWN"
    }

    private func nextEventText(solar: SolarDay) -> String {
        if solar.isPolarDay { return "NO SUNSET TODAY" }
        if solar.isPolarNight { return "NO SUNRISE TODAY" }
        guard let place = settings.solarCoordinate else { return "" }
        if solar.isDaylight(at: date), let sunset = solar.sunset {
            return "SUNSET " + settings.clockShortTime(sunset)
        }
        guard let sunrise = SolarCalculator.nextSunrise(after: date, latitude: place.latitude,
                                                        longitude: place.longitude,
                                                        timeZone: settings.clockTimeZone)
        else { return "" }
        return "SUNRISE " + settings.clockShortTime(sunrise)
    }

    // MARK: The sky itself

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      place: (latitude: Double, longitude: Double),
                      day: Date, solar: SolarDay) {
        guard size.width > 8, size.height > 8 else { return }
        // One sample per couple of points: fine enough that the twilight bands
        // read as a gradient, coarse enough to stay cheap on a TV-sized board.
        let step: CGFloat = 2
        let columns = max(2, Int((size.width / step).rounded(.up)))
        var altitudes: [Double] = []
        altitudes.reserveCapacity(columns + 1)
        for column in 0...columns {
            let moment = day.addingTimeInterval(Double(column) / Double(columns) * 86400)
            altitudes.append(SolarCalculator.altitude(at: moment, latitude: place.latitude,
                                                      longitude: place.longitude))
        }

        // The curve is scaled to the day it is drawing, so a winter day at a
        // high latitude still fills the panel instead of hugging the horizon.
        let highest = max(4, (altitudes.max() ?? 0) + 6)
        let lowest = min(-4, (altitudes.min() ?? 0) - 6)
        let axisHeight = min(size.height * 0.16, 18)
        let plotHeight = size.height - axisHeight
        func y(_ altitude: Double) -> CGFloat {
            let t = (highest - altitude) / (highest - lowest)
            return CGFloat(min(1, max(0, t))) * plotHeight
        }
        let horizonY = y(0)

        for column in 0..<columns {
            // The same scene the dial paints, sampled at that minute's sun —
            // one palette, so the two sun faces agree about what dusk is. Each
            // column is a slice of sky in its own right: deep overhead, the
            // sun's own color down at the horizon.
            let scene = SBSkyScene(sunAltitude: altitudes[column])
            let x = CGFloat(column) * step
            let width = step + 0.6   // overlap, so no hairline seams show
            context.fill(Path(CGRect(x: x, y: 0, width: width, height: horizonY)),
                         with: .linearGradient(
                            Gradient(colors: [scene.zenith, scene.middle, scene.horizon]),
                            startPoint: CGPoint(x: x, y: 0),
                            endPoint: CGPoint(x: x, y: horizonY)))
            context.fill(Path(CGRect(x: x, y: horizonY, width: width,
                                     height: size.height - horizonY)),
                         with: .color(scene.groundNear))
        }
        // The ground darkens with depth, once, across the whole band.
        context.fill(Path(CGRect(x: 0, y: horizonY, width: size.width,
                                 height: size.height - horizonY)),
                     with: .linearGradient(
                        Gradient(colors: [.black.opacity(0), .black.opacity(0.45)]),
                        startPoint: CGPoint(x: 0, y: horizonY),
                        endPoint: CGPoint(x: 0, y: size.height)))

        // The altitude curve, and the horizon it crosses twice a day.
        var curve = Path()
        for column in 0...columns {
            let point = CGPoint(x: CGFloat(column) * step, y: y(altitudes[column]))
            column == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }
        context.stroke(curve, with: .color(.white.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        context.stroke(Path { path in
            path.move(to: CGPoint(x: 0, y: horizonY))
            path.addLine(to: CGPoint(x: size.width, y: horizonY))
        }, with: .color(.white.opacity(0.35)), lineWidth: 1)

        drawHourAxis(in: &context, size: size, axisHeight: axisHeight)
        drawSunEvents(in: &context, size: size, solar: solar, horizonY: horizonY,
                      axisHeight: axisHeight)
        drawNow(in: &context, size: size, day: day, plotHeight: plotHeight,
                altitudes: altitudes, columns: columns, step: step, y: y)
    }

    /// Hours along the bottom, so the width reads as a day and not just as a
    /// gradient. Marks every three hours, labels every six.
    private func drawHourAxis(in context: inout GraphicsContext, size: CGSize,
                              axisHeight: CGFloat) {
        let top = size.height - axisHeight
        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: axisHeight)),
                     with: .color(.black.opacity(0.28)))
        for hour in stride(from: 0, through: 24, by: 3) {
            let x = size.width * CGFloat(hour) / 24
            context.stroke(Path { path in
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: top + axisHeight * 0.3))
            }, with: .color(.white.opacity(0.4)), lineWidth: 1)
            guard hour % 6 == 0, hour != 0, hour != 24, axisHeight > 10 else { continue }
            let label = Text(String(format: "%02d", hour))
                .font(SBTheme.titleFont(size: max(7, axisHeight * 0.55)))
                .foregroundStyle(.white.opacity(0.7))
            context.draw(label, at: CGPoint(x: x, y: top + axisHeight * 0.62))
        }
    }

    /// Sunrise and sunset, marked where the curve crosses the horizon.
    private func drawSunEvents(in context: inout GraphicsContext, size: CGSize,
                               solar: SolarDay, horizonY: CGFloat, axisHeight: CGFloat) {
        for (event, isRise) in [(solar.sunrise, true), (solar.sunset, false)] {
            guard let event else { continue }
            let x = size.width * CGFloat(fraction(of: event))
            context.stroke(Path { path in
                path.move(to: CGPoint(x: x, y: horizonY - 7))
                path.addLine(to: CGPoint(x: x, y: size.height - axisHeight))
            }, with: .color(.white.opacity(0.5)),
               style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let dot = CGRect(x: x - 3, y: horizonY - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(.white))
            guard size.width > 220 else { continue }
            let label = Text(settings.clockShortTime(event))
                .font(SBTheme.titleFont(size: 10))
                .foregroundStyle(.white.opacity(0.9))
            // Clamped inside the panel, and pushed to the daylight side of the
            // marker so it never sits on top of the other one.
            let offset: CGFloat = isRise ? 30 : -30
            context.draw(label, at: CGPoint(x: min(size.width - 26, max(26, x + offset)),
                                            y: horizonY + 12))
        }
    }

    /// Where the day has got to: a line down the whole panel and the sun on
    /// its curve.
    private func drawNow(in context: inout GraphicsContext, size: CGSize, day: Date,
                         plotHeight: CGFloat, altitudes: [Double], columns: Int,
                         step: CGFloat, y: (Double) -> CGFloat) {
        let t = fraction(of: date)
        let x = size.width * CGFloat(t)
        context.stroke(Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }, with: .color(.white.opacity(0.55)), lineWidth: 1)

        let index = min(columns, max(0, Int((x / step).rounded())))
        let position = CGPoint(x: x, y: y(altitudes[index]))
        let radius = max(5, min(size.height * 0.075, 11))
        let disc = CGRect(x: position.x - radius, y: position.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: disc.insetBy(dx: -radius, dy: -radius)),
                     with: .color(.white.opacity(altitudes[index] >= 0 ? 0.22 : 0.10)))
        context.fill(Path(ellipseIn: disc),
                     with: .color(altitudes[index] >= 0 ? .white : .white.opacity(0.65)))
    }

    /// How far through the local day an instant is, 0…1.
    private func fraction(of moment: Date) -> Double {
        min(1, max(0, moment.timeIntervalSince(dayStart) / 86400))
    }
}

// MARK: - Sun faces

/// The sun's path across the panel: sunrise at one end, sunset at the other,
/// the sun where it is now and a dip below the horizon overnight.
struct SunArcClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        guard let solar = settings.solarDay(at: date) else {
            return AnyView(ErrorView(
                message: "Set this panel's location to draw the sun's path"))
        }
        return AnyView(content(solar: solar))
    }

    private func content(solar: SolarDay) -> some View {
        GeometryReader { proxy in
            let horizon = proxy.size.height * 0.70
            VStack(spacing: 0) {
                ZStack {
                    Canvas { context, size in
                        draw(in: &context, size: size, solar: solar, horizon: horizon)
                    }
                }
                .frame(height: proxy.size.height * 0.78)
                HStack(alignment: .top, spacing: 6) {
                    endLabel(symbol: "sunrise.fill", time: solar.sunrise, title: "RISE",
                             alignment: .leading)
                    Spacer(minLength: 0)
                    Text(caption(solar: solar))
                        .font(SBTheme.titleFont(size: 11))
                        .foregroundStyle(sbStyle.textPrimary)
                        .kerning(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    endLabel(symbol: "sunset.fill", time: solar.sunset, title: "SET",
                             alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(8)
    }

    private func endLabel(symbol: String, time: Date?, title: String,
                          alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Label(title, systemImage: symbol)
                .font(SBTheme.titleFont(size: 9))
                .foregroundStyle(sbStyle.textSecondary)
                .kerning(1.2)
                .labelStyle(.titleAndIcon)
            Text(time.map(settings.clockShortTime) ?? "—")
                .font(SBTheme.lcdFont(size: 15))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func caption(solar: SolarDay) -> String {
        if solar.isPolarDay { return "THE SUN DOES NOT SET TODAY" }
        if solar.isPolarNight { return "THE SUN DOES NOT RISE TODAY" }
        if solar.isDaylight(at: date), let sunset = solar.sunset {
            return "SETS IN " + clockDurationText(sunset.timeIntervalSince(date)).uppercased()
        }
        guard let place = settings.solarCoordinate,
              let sunrise = SolarCalculator.nextSunrise(after: date, latitude: place.latitude,
                                                        longitude: place.longitude,
                                                        timeZone: settings.clockTimeZone)
        else { return "" }
        return "RISES IN " + clockDurationText(sunrise.timeIntervalSince(date)).uppercased()
    }

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      solar: SolarDay, horizon: CGFloat) {
        let left = size.width * 0.08
        let right = size.width * 0.92
        let peak = size.height * 0.14
        let amplitude = horizon - peak
        let dip = min(size.height - horizon, amplitude * 0.5)

        func dayPoint(_ t: Double) -> CGPoint {
            CGPoint(x: left + (right - left) * t,
                    y: horizon - amplitude * sin(.pi * min(1, max(0, t))))
        }
        func nightPoint(_ t: Double) -> CGPoint {
            // Overnight the sun runs back the other way, under the horizon.
            CGPoint(x: right - (right - left) * t,
                    y: horizon + dip * sin(.pi * min(1, max(0, t))))
        }

        // Sky above the horizon, warmer while the sun is up.
        let isDay = solar.isDaylight(at: date)
        let sky = Path(CGRect(x: 0, y: 0, width: size.width, height: horizon))
        context.fill(sky, with: .linearGradient(
            Gradient(colors: isDay
                     ? [accent.opacity(0.22), accent.opacity(0.04)]
                     : [sbStyle.textSecondary.opacity(0.16), .clear]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: horizon)))

        // The path itself: solid where the sun is up, dashed below.
        var dayPath = Path()
        dayPath.move(to: dayPoint(0))
        for step in 1...60 { dayPath.addLine(to: dayPoint(Double(step) / 60)) }
        context.stroke(dayPath, with: .color(accent.opacity(0.75)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        var nightPath = Path()
        nightPath.move(to: nightPoint(0))
        for step in 1...40 { nightPath.addLine(to: nightPoint(Double(step) / 40)) }
        context.stroke(nightPath, with: .color(sbStyle.textSecondary.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))

        // Horizon.
        let horizonPath = Path { path in
            path.move(to: CGPoint(x: 0, y: horizon))
            path.addLine(to: CGPoint(x: size.width, y: horizon))
        }
        context.stroke(horizonPath, with: .color(sbStyle.separator), lineWidth: 1)

        // Sunrise and sunset markers sit on the horizon at the arc's ends.
        for x in [left, right] {
            let marker = Path { path in
                path.move(to: CGPoint(x: x, y: horizon - 4))
                path.addLine(to: CGPoint(x: x, y: horizon + 4))
            }
            context.stroke(marker, with: .color(sbStyle.textSecondary.opacity(0.7)), lineWidth: 1)
        }

        // And the sun (or the moon) where it is now.
        let position: CGPoint
        let bodyColor: Color
        if solar.isPolarDay {
            position = dayPoint(0.5)
            bodyColor = accent
        } else if solar.isPolarNight {
            position = nightPoint(0.5)
            bodyColor = sbStyle.textSecondary
        } else if isDay {
            position = dayPoint(solar.daylightProgress(at: date))
            bodyColor = accent
        } else {
            position = nightPoint(nightProgress(solar: solar))
            bodyColor = sbStyle.textSecondary
        }
        let bodyRadius = max(4, min(size.height * 0.09, 12))
        let disc = CGRect(x: position.x - bodyRadius, y: position.y - bodyRadius,
                          width: bodyRadius * 2, height: bodyRadius * 2)
        context.fill(Path(ellipseIn: disc.insetBy(dx: -bodyRadius * 0.8, dy: -bodyRadius * 0.8)),
                     with: .color(bodyColor.opacity(0.18)))
        context.fill(Path(ellipseIn: disc), with: .color(bodyColor))
    }

    /// How far through the night it is, 0 at sunset and 1 at the next sunrise.
    private func nightProgress(solar: SolarDay) -> Double {
        guard let place = settings.solarCoordinate else { return 0.5 }
        let previousSunset: Date? = {
            if let sunset = solar.sunset, sunset <= date { return sunset }
            return SolarCalculator.day(containing: date.addingTimeInterval(-86400),
                                       latitude: place.latitude, longitude: place.longitude,
                                       timeZone: settings.clockTimeZone).sunset
        }()
        guard let start = previousSunset,
              let end = SolarCalculator.nextSunrise(after: date, latitude: place.latitude,
                                                    longitude: place.longitude,
                                                    timeZone: settings.clockTimeZone),
              end > start
        else { return 0.5 }
        return min(1, max(0, date.timeIntervalSince(start) / end.timeIntervalSince(start)))
    }
}

/// The same day in numbers: sunrise and sunset as times, with the daylight
/// bar between them and how much of it is left.
struct SunTimesClockFace: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let settings: PanelSettings
    let date: Date

    var body: some View {
        guard let solar = settings.solarDay(at: date) else {
            return AnyView(ErrorView(
                message: "Set this panel's location to show sunrise and sunset"))
        }
        return AnyView(content(solar: solar))
    }

    private func content(solar: SolarDay) -> some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.height, proxy.size.width * 0.32)
            VStack(alignment: .leading, spacing: scale * 0.1) {
                HStack(alignment: .top, spacing: scale * 0.16) {
                    // Inside the polar circles neither event happens, and a
                    // lone dash reads as a bug rather than as an answer.
                    let missing = (solar.isPolarDay || solar.isPolarNight) ? "NONE" : "—"
                    timeColumn(title: "SUNRISE", symbol: "sunrise.fill", time: solar.sunrise,
                               missing: missing, scale: scale)
                    Spacer(minLength: 0)
                    timeColumn(title: "SUNSET", symbol: "sunset.fill", time: solar.sunset,
                               missing: missing, scale: scale, alignment: .trailing)
                }
                DaylightBar(solar: solar, settings: settings, date: date,
                            height: max(5, scale * 0.13))
                HStack(spacing: 6) {
                    Text(daylightText(solar: solar))
                        .font(SBTheme.titleFont(size: max(9, min(scale * 0.16, 14))))
                        .foregroundStyle(sbStyle.textSecondary)
                        .kerning(1)
                    Spacer(minLength: 0)
                    Text(remainingText(solar: solar))
                        .font(SBTheme.titleFont(size: max(9, min(scale * 0.16, 14))))
                        .foregroundStyle(accent)
                        .kerning(1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .padding(10)
    }

    private func timeColumn(title: String, symbol: String, time: Date?, missing: String,
                            scale: CGFloat,
                            alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Label(title, systemImage: symbol)
                .font(SBTheme.titleFont(size: max(8, min(scale * 0.15, 12))))
                .foregroundStyle(sbStyle.textSecondary)
                .kerning(1.4)
            Text(time.map(settings.clockShortTime) ?? missing)
                .font(SBTheme.lcdFont(size: max(16, min(scale * 0.42, 44))))
                .foregroundStyle(alignment == .leading ? accent : sbStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private func daylightText(solar: SolarDay) -> String {
        if solar.isPolarDay { return "DAYLIGHT ALL DAY" }
        if solar.isPolarNight { return "NO DAYLIGHT TODAY" }
        guard let daylight = solar.daylight else { return "" }
        return "DAYLIGHT " + clockDurationText(daylight).uppercased()
    }

    private func remainingText(solar: SolarDay) -> String {
        if solar.isPolarDay || solar.isPolarNight { return "" }
        if solar.isDaylight(at: date), let sunset = solar.sunset {
            return clockDurationText(sunset.timeIntervalSince(date)).uppercased() + " LEFT"
        }
        guard let place = settings.solarCoordinate,
              let sunrise = SolarCalculator.nextSunrise(after: date, latitude: place.latitude,
                                                        longitude: place.longitude,
                                                        timeZone: settings.clockTimeZone)
        else { return "" }
        return "RISES IN " + clockDurationText(sunrise.timeIntervalSince(date)).uppercased()
    }
}

/// Sunrise → sunset as a track, with a marker for now. Shared by the modular
/// and sunrise-and-sunset faces.
struct DaylightBar: View {
    @Environment(\.sbStyle) private var sbStyle
    @Environment(\.panelAccent) private var accent
    let solar: SolarDay
    let settings: PanelSettings
    let date: Date
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let progress = solar.isPolarNight ? 0 : solar.daylightProgress(at: date)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(sbStyle.separator.opacity(sbStyle.isLight ? 0.5 : 0.8))
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.55), accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, proxy.size.width * progress))
                Circle()
                    .fill(sbStyle.textPrimary)
                    .frame(width: height * 1.5, height: height * 1.5)
                    .offset(x: min(proxy.size.width - height * 1.5,
                                   max(0, proxy.size.width * progress - height * 0.75)))
                    .opacity(solar.isDaylight(at: date) ? 1 : 0)
            }
        }
        .frame(height: height)
    }
}
