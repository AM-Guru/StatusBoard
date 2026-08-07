import Foundation
#if canImport(EventKit) && !os(tvOS)
import EventKit
#endif

/// Upcoming events from the system calendar (EventKit), presented as feed
/// items. tvOS has no EventKit — calendar panels there suggest using a
/// synced device or the bridge.
public enum CalendarSource {
    #if canImport(EventKit) && !os(tvOS)
    private static let store = EKEventStore()

    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted:
            return .error("Allow calendar access in Settings to show events")
        default:
            break
        }

        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else {
                return .error("Allow calendar access in Settings to show events")
            }
        } catch {
            return .error(describe(error))
        }

        let start = Date()
        let days = max(1, min(60, settings.calendarDaysAhead))
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(30)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        let items = events.map { event in
            FeedItem(id: event.eventIdentifier ?? UUID().uuidString,
                     title: event.title ?? "Untitled",
                     link: nil,
                     published: event.startDate)
        }
        guard !items.isEmpty else {
            return .feed([FeedItem(title: "No events in the next \(days) days")])
        }
        return .feed(Array(items))
    }

    /// EventKit reports a sandbox denial as a raw Mach send failure, so the
    /// panel used to read "Mach error 4099 - unknown error code" — which says
    /// nothing about the actual cause. The connection to the calendar daemon
    /// was refused because the bundle lacks
    /// `com.apple.security.personal-information.calendars`; no permission
    /// dialog is ever shown, so waiting for one or resetting privacy settings
    /// does nothing.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSMachErrorDomain {
            return "macOS blocked the connection to Calendar. This build isn't "
                + "entitled to read calendars — install a newer build."
        }
        return nsError.localizedDescription
    }
    #else
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        .error("Calendars aren't available on Apple TV — this panel works on iPhone, iPad, and Mac")
    }
    #endif
}

/// Fetches an image URL on the panel's refresh interval — the "digital
/// picture frame" panel reviewers asked Panic for.
public enum ImageSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard let urlString = settings.url, let url = URL(string: urlString) else {
            return .error("Set an image URL in the panel settings")
        }
        do {
            let data = try await WebQuerySource.fetch(url: url)
            guard !data.isEmpty else { return .error("Empty image response") }
            return .image(data)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
