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
