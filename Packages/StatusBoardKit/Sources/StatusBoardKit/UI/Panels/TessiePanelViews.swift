import SwiftUI
#if canImport(MapKit)
import MapKit
#endif

/// The Tesla panel.
///
/// The layout is built from an ordered list of fields, and there are two of
/// them — one for parked, one for driving — so the panel rearranges itself
/// when someone pulls out of the driveway. Whichever list is in play, the
/// first field with data becomes the headline, the map (wherever it sits in
/// the list) gets its own block, and the rest become tiles.
struct TessiePanelView: View {
    let vehicle: TessieVehicle
    let settings: PanelSettings

    @Environment(\.sbStyle) private var style

    private var context: TessieContext {
        TessieReadout.context(for: vehicle, settings: settings)
    }

    private var fields: [TessieField] {
        TessieReadout.fields(for: context, settings: settings)
    }

    private var stats: [TessieStat] {
        TessieReadout.stats(for: vehicle, fields: fields.filter { $0 != .map })
    }

    private var showsMap: Bool {
        fields.contains(.map) && vehicle.place.hasCoordinate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let hero = stats.first {
                TessieHeroView(stat: hero, vehicle: vehicle)
            }
            if showsMap {
                TessieMapView(vehicle: vehicle)
                    .frame(minHeight: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if stats.count > 1 {
                TessieStatGrid(stats: Array(stats.dropFirst()))
            }
            if stats.isEmpty && !showsMap {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    /// Name, whether the car is awake, and the two states worth interrupting
    /// for wherever they happen to be in the field list.
    private var header: some View {
        HStack(spacing: 6) {
            Text(vehicle.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(style.textPrimary)
                .lineLimit(1)

            if vehicle.isDriving {
                TessieBadge(text: vehicle.drive.gear.displayName.uppercased(),
                            symbol: "car.side.fill", tone: .accent)
            } else if vehicle.isCharging {
                TessieBadge(text: "CHARGING", symbol: "bolt.fill", tone: .good)
            } else if vehicle.isAsleep {
                TessieBadge(text: vehicle.connection.displayName.uppercased(),
                            symbol: "moon.zzz.fill", tone: .neutral)
            }

            Spacer(minLength: 0)

            // Unlocked or standing open is worth saying no matter which
            // fields the board was configured with.
            if vehicle.security.isLocked == false {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(style.bad)
            }
            if !vehicle.security.openings.isEmpty {
                Image(systemName: "door.left.hand.open")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(style.warn)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "car.side")
                .font(.system(size: 24))
                .foregroundStyle(style.textSecondary)
            Text(vehicle.isAsleep ? "Asleep — no recent data" : "Nothing to show")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(style.textSecondary)
            Text("Pick fields to display in the panel's settings.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(style.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Headline

/// The one number you read from across the room.
struct TessieHeroView: View {
    let stat: TessieStat
    let vehicle: TessieVehicle

    @Environment(\.sbStyle) private var style

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stat.label.uppercased())
                    .font(SBTheme.titleFont(size: 9))
                    .kerning(1.2)
                    .foregroundStyle(style.textSecondary)
                Text(stat.value)
                    .font(SBTheme.lcdFont(size: 32))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                if let detail = stat.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(style.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let fraction = stat.fraction {
                TessieBatteryGlyph(fraction: fraction, tint: tint,
                                   isCharging: vehicle.isCharging)
            } else {
                Image(systemName: stat.field.symbolName)
                    .font(.system(size: 26))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
    }

    private var tint: Color { stat.tone.color(in: style) }
}

/// A battery that actually looks like one — a wall display is read at a
/// glance, and a shape carries a level faster than digits do.
struct TessieBatteryGlyph: View {
    let fraction: Double
    let tint: Color
    var isCharging = false

    @Environment(\.sbStyle) private var style

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(style.separator, lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(tint)
                    .padding(2.5)
                    .scaleEffect(x: max(0.02, min(1, fraction)), y: 1, anchor: .leading)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(style.onAccent)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 46, height: 24)
            Capsule()
                .fill(style.separator)
                .frame(width: 3, height: 9)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tiles

struct TessieStatGrid: View {
    let stats: [TessieStat]

    @Environment(\.sbStyle) private var style

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 220), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Image(systemName: stat.field.symbolName)
                            .font(.system(size: 8, weight: .bold))
                        Text(stat.label.uppercased())
                            .font(SBTheme.titleFont(size: 8))
                            .kerning(0.8)
                            .lineLimit(1)
                    }
                    .foregroundStyle(style.textSecondary)
                    Text(stat.value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(stat.tone.color(in: style))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let detail = stat.detail {
                        Text(detail)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(style.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .background(style.separator.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

struct TessieBadge: View {
    let text: String
    let symbol: String
    let tone: TessieStat.Tone

    @Environment(\.sbStyle) private var style

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .black))
            Text(text)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .kerning(0.5)
        }
        .foregroundStyle(tone.color(in: style))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tone.color(in: style).opacity(0.18), in: Capsule())
    }
}

extension TessieStat.Tone {
    func color(in style: SBPanelStyle) -> Color {
        switch self {
        case .neutral: return style.textPrimary
        case .accent: return style.accent
        case .good: return style.good
        case .warn: return style.warn
        case .bad: return style.bad
        }
    }
}

// MARK: - Map

/// Where the car is, on Apple Maps — and, when a route is running, where it is
/// headed, so the two are visible in the same glance.
struct TessieMapView: View {
    let vehicle: TessieVehicle

    @Environment(\.sbStyle) private var style
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        #if canImport(MapKit)
        // ImageRenderer rasterises a map as an empty rectangle, so an exported
        // board would show a grey hole where the car should be. Same handling
        // as the web-clip panels.
        if isStaticRender {
            staticFallback
        } else {
            Map(position: .constant(.region(region)), interactionModes: []) {
                Annotation(vehicle.name, coordinate: carCoordinate) {
                    carMarker
                }
                if let destination = destinationCoordinate {
                    Annotation(vehicle.route?.destination ?? "Destination",
                               coordinate: destination) {
                        Image(systemName: "flag.checkered.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(style.textPrimary, style.good)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            // Panels are dark; a bright map in the middle of one glares.
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
        }
        #else
        staticFallback
        #endif
    }

    /// The car, pointed the way it is actually facing while driving.
    private var carMarker: some View {
        ZStack {
            Circle()
                .fill(style.accent)
                .frame(width: 16, height: 16)
                .shadow(color: style.accent.opacity(0.7), radius: 5)
            if vehicle.isDriving, let heading = vehicle.drive.headingDegrees {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(style.onAccent)
                    .rotationEffect(.degrees(heading))
            } else {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(style.onAccent)
            }
        }
    }

    private var staticFallback: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(vehicle.place.shortDescription ?? "Location unknown",
                  systemImage: "mappin.and.ellipse")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(style.textPrimary)
                .lineLimit(2)
            if let destination = vehicle.route?.destination {
                Label("→ \(destination)", systemImage: "flag.checkered")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(style.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(style.separator.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    #if canImport(MapKit)
    private var carCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: vehicle.place.latitude ?? 0,
                               longitude: vehicle.place.longitude ?? 0)
    }

    private var destinationCoordinate: CLLocationCoordinate2D? {
        guard let route = vehicle.route, let latitude = route.latitude,
              let longitude = route.longitude, route.hasCoordinate else { return nil }
        // Tesla reports 0,0 for a route whose destination has no coordinate.
        guard latitude != 0 || longitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Frames the car alone when parked, and both ends of the route when one
    /// is running — the point of the map while driving is the relationship
    /// between the two, not either one on its own.
    private var region: MKCoordinateRegion {
        guard let destination = destinationCoordinate else {
            let span = vehicle.isDriving ? 0.012 : 0.006
            return MKCoordinateRegion(center: carCoordinate,
                                      span: MKCoordinateSpan(latitudeDelta: span,
                                                             longitudeDelta: span))
        }
        let center = CLLocationCoordinate2D(
            latitude: (carCoordinate.latitude + destination.latitude) / 2,
            longitude: (carCoordinate.longitude + destination.longitude) / 2)
        // 40% padding so neither pin sits on the edge of the panel.
        let latitudeDelta = abs(carCoordinate.latitude - destination.latitude) * 1.4
        let longitudeDelta = abs(carCoordinate.longitude - destination.longitude) * 1.4
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: max(latitudeDelta, 0.005),
                                   longitudeDelta: max(longitudeDelta, 0.005)))
    }
    #endif
}
