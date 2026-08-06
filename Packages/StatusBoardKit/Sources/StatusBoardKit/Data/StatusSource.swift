import Foundation

/// Pings a list of HTTP endpoints and reports up/degraded/down.
public enum StatusSource {
    public static func fetch(settings: PanelSettings) async -> DataSnapshot {
        guard !settings.statusTargets.isEmpty else {
            return .error("Add services in the panel settings")
        }
        let targets = settings.statusTargets
        var results: [ServiceStatus] = []
        await withTaskGroup(of: ServiceStatus.self) { group in
            for target in targets {
                group.addTask { await check(target) }
            }
            for await status in group {
                results.append(status)
            }
        }
        // Preserve configured order.
        let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1.id, $0) })
        results.sort { (order[UUID(uuidString: $0.id) ?? UUID()] ?? 0) < (order[UUID(uuidString: $1.id) ?? UUID()] ?? 0) }
        return .statuses(results)
    }

    static func check(_ target: StatusTarget) async -> ServiceStatus {
        guard let url = URL(string: target.url) else {
            return ServiceStatus(id: target.id.uuidString, name: target.name,
                                 state: .unknown, detail: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(started) * 1000
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let state: ServiceStatus.State
            switch code {
            case 200..<400: state = latency > 2000 ? .degraded : .up
            case 400..<500: state = .degraded
            default: state = .down
            }
            return ServiceStatus(id: target.id.uuidString, name: target.name,
                                 state: state, latencyMS: latency, detail: "HTTP \(code)")
        } catch {
            return ServiceStatus(id: target.id.uuidString, name: target.name,
                                 state: .down, detail: error.localizedDescription)
        }
    }
}
