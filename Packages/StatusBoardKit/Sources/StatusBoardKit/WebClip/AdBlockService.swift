#if canImport(WebKit)
import Foundation
import WebKit

/// Compiles content-blocking rules for the web views that render web clips.
///
/// Rules come from **EasyList** — the open-source list that Adblock Plus,
/// uBlock Origin and 1Blocker all build on — fetched on demand, converted to
/// WebKit's native format, compiled once and cached by
/// `WKContentRuleListStore`. A small built-in list ships in-app so blocking
/// works offline and on the very first load, before the download lands.
@MainActor
public final class AdBlockService {
    public static let shared = AdBlockService()

    /// Open-source filter lists we build on. EasyList covers ads; EasyPrivacy
    /// covers trackers and analytics — they are deliberately separate lists, so
    /// we fetch and compile both.
    struct Source {
        var identifier: String
        var mirrors: [String]
        var cacheName: String
    }

    static let sources = [
        Source(identifier: "statusboard.easylist",
               mirrors: ["https://easylist.to/easylist/easylist.txt",
                         "https://raw.githubusercontent.com/easylist/easylist/master/easylist.txt"],
               cacheName: "easylist.txt"),
        Source(identifier: "statusboard.easyprivacy",
               mirrors: ["https://easylist.to/easylist/easyprivacy.txt",
                         "https://raw.githubusercontent.com/easylist/easylist/master/easyprivacy.txt"],
               cacheName: "easyprivacy.txt"),
    ]

    private static let seedIdentifier = "statusboard.seed"

    private var compiled: [String: WKContentRuleList] = [:]
    private var refreshTasks: [String: Task<WKContentRuleList?, Never>] = [:]

    private func cacheURL(for source: Source) -> URL {
        SBStorage.localSupportURL().appendingPathComponent(source.cacheName)
    }
    private func cacheDateKey(for source: Source) -> String {
        "sb.\(source.identifier).fetchedAt"
    }

    private init() {}

    /// Every ruleset available right now. The built-in seed is *always*
    /// included: the downloaded lists are deliberately scoped (EasyList has no
    /// generic `.ad` cosmetic rule and no analytics domains), so dropping the
    /// seed once they arrive would silently weaken blocking.
    public func currentRuleLists() async -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        if let seed = await seedRuleList() { lists.append(seed) }
        for source in Self.sources {
            if let compiled = compiled[source.identifier] { lists.append(compiled) }
        }
        // Build anything not ready yet, for next time.
        Task { await self.ensureDownloadedLists() }
        return lists
    }

    /// Downloads/loads the filter lists and compiles them. Safe to call
    /// repeatedly — concurrent callers share one build per source.
    public func ensureDownloadedLists() async {
        await withTaskGroup(of: Void.self) { group in
            for source in Self.sources {
                group.addTask { @MainActor [weak self] in
                    _ = await self?.ensure(source)
                }
            }
        }
    }

    @discardableResult
    private func ensure(_ source: Source) async -> WKContentRuleList? {
        if let existing = compiled[source.identifier] { return existing }
        if let running = refreshTasks[source.identifier] { return await running.value }

        let task = Task<WKContentRuleList?, Never> { [weak self] in
            guard let self else { return nil }
            // A previously compiled list survives app launches in the store.
            if let cached = try? await WKContentRuleListStore.default()?
                .contentRuleList(forIdentifier: source.identifier),
               !self.isCacheStale(source) {
                self.compiled[source.identifier] = cached
                return cached
            }
            guard let text = await self.loadFilterText(source) else { return nil }
            let rules = AdBlockRuleConverter.convert(filterList: text)
            guard !rules.isEmpty else { return nil }
            let json = AdBlockRuleConverter.json(for: rules)
            let list = try? await WKContentRuleListStore.default()?
                .compileContentRuleList(forIdentifier: source.identifier,
                                        encodedContentRuleList: json)
            if let list { self.compiled[source.identifier] = list }
            return list
        }
        refreshTasks[source.identifier] = task
        let result = await task.value
        refreshTasks[source.identifier] = nil
        return result
    }

    private func seedRuleList() async -> WKContentRuleList? {
        if let existing = compiled[Self.seedIdentifier] { return existing }
        let rules = AdBlockRuleConverter.convert(filterList: Self.seedFilters)
        let json = AdBlockRuleConverter.json(for: rules)
        let list = try? await WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: Self.seedIdentifier,
                                    encodedContentRuleList: json)
        if let list { compiled[Self.seedIdentifier] = list }
        return list
    }

    // MARK: - Filter text

    private func isCacheStale(_ source: Source) -> Bool {
        let defaults = UserDefaults.standard
        let fetched = defaults.double(forKey: cacheDateKey(for: source))
        guard fetched > 0 else { return true }
        // The lists update a few times a day; weekly is plenty for a dashboard.
        return Date().timeIntervalSince1970 - fetched > 7 * 24 * 3600
    }

    private func loadFilterText(_ source: Source) async -> String? {
        let cache = cacheURL(for: source)
        if !isCacheStale(source), let cached = try? String(contentsOf: cache, encoding: .utf8) {
            return cached
        }
        for mirror in source.mirrors {
            guard let url = URL(string: mirror) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8),
                  text.count > 1000 else { continue }
            try? text.write(to: cache, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: cacheDateKey(for: source))
            return text
        }
        // Download failed — fall back to any stale copy we already have.
        return try? String(contentsOf: cache, encoding: .utf8)
    }

    /// A compact built-in list so blocking is never nothing: the biggest ad
    /// and tracking networks, plus the usual cookie/consent furniture that
    /// otherwise covers a web clip.
    static let seedFilters = """
    ||doubleclick.net^
    ||googlesyndication.com^
    ||googleadservices.com^
    ||google-analytics.com^
    ||googletagmanager.com^
    ||googletagservices.com^
    ||adservice.google.com^
    ||amazon-adsystem.com^
    ||adnxs.com^
    ||rubiconproject.com^
    ||pubmatic.com^
    ||openx.net^
    ||criteo.com^
    ||criteo.net^
    ||taboola.com^
    ||outbrain.com^
    ||scorecardresearch.com^
    ||quantserve.com^
    ||moatads.com^
    ||adsafeprotected.com^
    ||casalemedia.com^
    ||smartadserver.com^
    ||teads.tv^
    ||sharethrough.com^
    ||facebook.net^$third-party
    ||connect.facebook.net^
    ||hotjar.com^
    ||mixpanel.com^
    ||segment.io^
    ||branch.io^
    ||onesignal.com^
    ||chartbeat.com^
    ||parsely.com^
    ||newrelic.com^$third-party
    ||optimizely.com^
    ||cookielaw.org^
    ||cookiebot.com^
    ||onetrust.com^
    ||usercentrics.eu^
    ||quantcast.mgr.consensu.org^
    ##.ad
    ##.ads
    ##.advert
    ##.advertisement
    ##.ad-container
    ##.ad-banner
    ##.ad-wrapper
    ##.adsbygoogle
    ##.cookie-banner
    ##.cookie-consent
    ##.cookie-notice
    ##.gdpr-banner
    ##.newsletter-popup
    ##.paywall-overlay
    ##[id^="google_ads_"]
    ##[id^="div-gpt-ad"]
    ##[class*="taboola"]
    ##[class*="outbrain"]
    ##iframe[src*="doubleclick.net"]
    ##iframe[src*="googlesyndication.com"]
    """
}
#endif
