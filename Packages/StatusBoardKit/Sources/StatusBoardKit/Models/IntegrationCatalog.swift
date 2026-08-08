import Foundation

/// Code-backed help for every panel integration. `descriptor(for:)` is an
/// exhaustive switch, so adding a panel kind cannot compile until its setup
/// documentation is added too.
public struct IntegrationDescriptor: Identifiable, Hashable, Sendable {
    public var id: PanelKind { kind }
    public var kind: PanelKind
    public var dataSource: String
    public var configuration: String
    public var platforms: String
    public var appleTVDelivery: String
    public var acceptsTerminalInput: Bool
    public var supportsAppIntents: Bool
    public var supportsSiri: Bool
    /// Every panel is selectable by the configurable Status Board WidgetKit
    /// extension; sources that cannot run in an extension use their snapshot.
    public var supportsWidgetKit: Bool = true
}

public enum IntegrationCatalog {
    public static var all: [IntegrationDescriptor] {
        PanelKind.allCases.map(descriptor(for:))
    }

    public static func descriptor(for kind: PanelKind) -> IntegrationDescriptor {
        let acceptsPush = kind == .bridge || kind == .graph || kind == .progress
        return IntegrationDescriptor(
            kind: kind,
            dataSource: source(for: kind),
            configuration: configuration(for: kind),
            platforms: platforms(for: kind),
            appleTVDelivery: tvDelivery(for: kind),
            acceptsTerminalInput: acceptsPush,
            supportsAppIntents: acceptsPush,
            supportsSiri: acceptsPush)
    }

    private static func source(for kind: PanelKind) -> String {
        switch kind {
        case .clock, .countdown, .text: return "On-device"
        case .weather: return "Location + weather providers"
        case .graph, .progress: return "Mac bridge key or JSON URL"
        case .feed: return "RSS / Atom URLs"
        case .calendar: return "Apple Calendar (EventKit)"
        case .webClip: return "Web page / Mac-rendered snapshot"
        case .image: return "Image URL"
        case .table: return "JSON or CSV URL"
        case .status: return "HTTP service checks"
        case .mcp: return "Model Context Protocol server"
        case .bridge: return "Mac bridge, sbctl, Shortcuts, or Siri"
        case .github: return "GitHub API"
        case .appStoreConnect: return "App Store Connect API"
        case .supabase: return "Supabase REST API"
        case .logs: return "Log endpoint or bridge stream"
        case .health: return "Apple Health (HealthKit)"
        case .canvas: return "Canvas / Instructure API"
        case .k12schedule, .grades, .schedule, .assignments: return "School portal / Canvas"
        case .tessie: return "Tessie API"
        case .homeKit: return "Apple Home (HomeKit)"
        case .homeAssistant: return "Home Assistant REST API"
        case .nest: return "Google Device Access (Nest)"
        }
    }

    private static func configuration(for kind: PanelKind) -> String {
        switch kind {
        case .clock: return "Choose a face, time zone, hour format, date, seconds, and optional location-driven solar display."
        case .weather: return "Current Location is the default. You can also choose a place, public station, coordinates, or personal station, plus units and forecast direction."
        case .graph: return "Enter a bridge key or JSON URL, optional JSON paths and unit, then choose a chart style."
        case .progress: return "Enter a bridge key or JSON URL, value path and optional total, then choose a progress style."
        case .feed: return "Add one or more RSS/Atom URLs, optionally name, reorder, disable, and merge them."
        case .calendar: return "Grant Calendar access, select calendars (or leave all selected), choose days ahead and list/ticker display."
        case .webClip: return "Enter a URL, select the page region, hide elements, choose zoom, and optionally save sign-in in Keychain."
        case .image: return "Enter an image URL and optional filter chain."
        case .text: return "Enter the text shown by the panel."
        case .countdown: return "Choose a target date and time."
        case .table: return "Enter a JSON/CSV URL and optional rows path; configure header, striping, and status colors."
        case .status: return "Add named HTTP/HTTPS endpoints to monitor."
        case .mcp: return "Choose HTTP or stdio transport, server details, tool name, and JSON arguments."
        case .bridge: return "Choose a key, then push text or numbers with sbctl, HTTP, Shortcuts, Siri, or the Mac metrics bridge."
        case .github: return "Choose repository/query settings and provide a GitHub token when private data is needed."
        case .appStoreConnect: return "Provide issuer ID, key ID, private key, and the desired report/query."
        case .supabase: return "Provide project URL, API key, table/query, and display mode."
        case .logs: return "Provide a log endpoint/query or stream lines to a bridge key with sbctl pipe."
        case .health: return "Choose a Health metric and grant Health access. Portable snapshot syncing is opt-in."
        case .canvas: return "Enter the Canvas host and access token; the sign-in is shared with Grades and Assignments panels."
        case .k12schedule: return "Sign in to the supported K12 portal and choose schedule display options."
        case .grades: return "Sign in to Canvas or the school portal, then rename or hide courses as needed."
        case .schedule: return "Sign in to the school portal; the Mac bridge can supply sessions to Apple TV."
        case .assignments: return "Sign in to Canvas and configure course visibility."
        case .tessie: return "Enter one Tessie API key, choose a vehicle, and configure parked/driving fields."
        case .homeKit: return "Grant Home access; choose a home, rooms, accessory/mode, sensor types, and diagnostics."
        case .homeAssistant: return "Enter the server URL and long-lived token, then choose rooms/entities and mode."
        case .nest: return "Complete Google Device Access OAuth, then choose the thermostat and display mode."
        }
    }

    private static func platforms(for kind: PanelKind) -> String {
        switch kind {
        case .calendar: return "Mac, iPhone, iPad, Watch; snapshot on Apple TV"
        case .health: return "iPhone, iPad, Watch; synced/bridged elsewhere"
        case .webClip: return "Mac, iPhone, iPad; Mac-rendered snapshot on Apple TV"
        case .homeKit: return "HomeKit-capable devices; synced/bridged fallback"
        default: return "Mac, iPhone, iPad, Apple TV, Apple Watch"
        }
    }

    private static func tvDelivery(for kind: PanelKind) -> String {
        switch kind {
        case .calendar, .health, .homeKit:
            return "Private iCloud snapshot or live Mac bridge relay"
        case .webClip, .k12schedule, .grades, .schedule, .assignments:
            return "Mac bridge supplies content that tvOS cannot sign into or render"
        default:
            return "Direct when supported; latest Mac relay is retained as fallback"
        }
    }
}
