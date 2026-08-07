import Foundation
import CloudKit
import Observation
#if os(macOS)
import Security
#endif

/// Syncs dashboards through the user's private CloudKit database using
/// CKSyncEngine. Each dashboard is one record carrying its JSON payload.
@MainActor
@Observable
public final class CloudSyncEngine: NSObject {
    public enum State: Equatable {
        case idle
        case syncing
        case unavailable(String)
    }

    public private(set) var state: State = .idle
    /// When boards last arrived from — or were last checked against — iCloud.
    /// Shown on Apple TV, where it's the only sign sync is working.
    public private(set) var lastSyncDate: Date?
    /// The last CloudKit error, kept so a display can say *why* nothing
    /// arrived. These used to be swallowed by `try?`, which is how an Apple TV
    /// could sit on "Waiting for Boards" forever with no clue that, say, the
    /// record type had never been deployed to the production environment.
    public private(set) var lastErrorMessage: String?

    @ObservationIgnored private let store: DashboardStore
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let zoneID = CKRecordZone.ID(zoneName: "StatusBoards")
    @ObservationIgnored private let stateURL: URL

    private static let recordType: CKRecord.RecordType = "Dashboard"
    private static let payloadKey = "payload"

    public init(store: DashboardStore) {
        self.store = store
        self.stateURL = SBStorage.localSupportURL()
            .appendingPathComponent("cksync-state.data")
        super.init()

        store.onLocalSave = { [weak self] dashboard in
            self?.enqueueSave(dashboard.id)
        }
        store.onLocalDelete = { [weak self] id in
            self?.enqueueDelete(id)
        }
    }

    public func start() {
        guard engine == nil, startTask == nil else { return }
        guard Self.processHasCloudKitEntitlement() else {
            state = .unavailable(Self.unentitledReason)
            return
        }
        let container = CKContainer(identifier: SBIdentifiers.cloudContainer)
        startTask = Task { @MainActor [weak self] in
            defer { self?.startTask = nil }
            // Ask CloudKit itself whether there's an account. The obvious
            // alternative, `FileManager.ubiquityIdentityToken`, reports the
            // iCloud *Drive* identity — which Apple TV doesn't have at all, so
            // it reads nil on a perfectly well signed-in Apple TV and sync
            // would never start there.
            do {
                let status = try await container.accountStatus()
                guard status == .available else {
                    self?.state = .unavailable(Self.describe(status))
                    return
                }
            } catch {
                self?.state = .unavailable("Could not reach iCloud: \(error.localizedDescription)")
                return
            }
            self?.startEngine(container: container)
        }
    }

    private func startEngine(container: CKContainer) {
        guard engine == nil else { return }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadStateSerialization(),
            delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        state = .idle
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        // Push what we have locally; CloudKit dedupes by record change tag.
        // Display-only devices have nothing of their own to contribute — their
        // copies are a cache of iCloud, so pushing them back can only conflict.
        guard store.authorsBoards else { return }
        for dashboard in store.dashboards {
            enqueueSave(dashboard.id)
        }
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return "Sign in to iCloud to sync dashboards"
        case .restricted: return "iCloud is restricted on this device"
        case .couldNotDetermine: return "Could not check your iCloud account"
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable"
        default: return "iCloud is unavailable"
        }
    }

    public func syncNow() async {
        // The engine may never have started — no account at launch, no network,
        // signed in afterwards. This is the button the user reaches for when
        // boards haven't arrived, so retry from the top rather than do nothing.
        if engine == nil {
            start()
            await startTask?.value
        }
        guard let engine else { return }
        state = .syncing
        defer {
            // An account change can land mid-fetch and report itself through
            // the delegate; don't paper over it with .idle.
            if case .unavailable = state {} else { state = .idle }
            lastSyncDate = Date()
        }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = Self.describe(error)
        }
    }

    /// Keeps checking iCloud on the devices that can't ask for themselves.
    ///
    /// CloudKit's push is what would deliver boards unprompted, and it only
    /// arrives on a build whose `aps-environment` matches how it was signed —
    /// so a sideloaded Apple TV build gets nothing, and the board picker's
    /// refresh row is behind a swipe the user has no reason to think is
    /// needed. Polling hard while the screen is empty is the difference
    /// between "it works" and "it never worked"; once boards are up, the
    /// interval relaxes to something a wall display can run on all day.
    public func startAutomaticRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            var emptyRounds = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow()
                let isEmpty = self.store.dashboards.isEmpty
                emptyRounds = isEmpty ? emptyRounds + 1 : 0
                // 30s, doubling to 4 minutes while nothing has arrived;
                // a quarter-hour once there's something on screen.
                let seconds = isEmpty
                    ? min(30 << min(emptyRounds - 1, 3), 240)
                    : 900
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func stopAutomaticRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A CloudKit failure in terms of what the user can actually do about it.
    private static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        switch ckError.code {
        case .notAuthenticated:
            return "Sign in to iCloud to receive boards"
        case .networkUnavailable, .networkFailure:
            return "No network connection to iCloud"
        case .quotaExceeded:
            return "This iCloud account is out of storage"
        case .managedAccountRestricted, .permissionFailure:
            return "This iCloud account isn't allowed to sync boards"
        case .invalidArguments, .badContainer, .badDatabase:
            // Almost always the schema: record types auto-create in the
            // development environment only, so a TestFlight or App Store build
            // finds nothing until the schema is deployed to production in the
            // CloudKit Console.
            return "iCloud rejected the board format — the CloudKit schema may not be deployed to production"
        case .zoneNotFound, .userDeletedZone:
            return "No boards have been uploaded to iCloud yet"
        default:
            return ckError.localizedDescription
        }
    }

    /// One line describing where boards stand, for displays that have no other
    /// way to report it.
    public var statusDetail: String {
        switch state {
        case .unavailable(let reason):
            return reason
        case .syncing:
            return "Checking iCloud…"
        case .idle:
            if let lastErrorMessage { return lastErrorMessage }
            let count = store.dashboards.count
            let boards = "\(count) board\(count == 1 ? "" : "s") synced"
            guard let lastSyncDate else { return boards }
            return "\(boards) · Checked \(Self.relative.localizedString(for: lastSyncDate, relativeTo: Date()))"
        }
    }

    /// True when the status line is reporting a problem rather than progress.
    public var isHealthy: Bool {
        if case .unavailable = state { return false }
        return lastErrorMessage == nil
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// CKContainer raises an uncatchable NSException — the process dies on the
    /// spot, it cannot be caught — when the container isn't in the running
    /// process's entitlements. So never construct one without checking first.
    private static func processHasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-services" as CFString, nil)
        return value != nil
        #elseif targetEnvironment(simulator)
        // Simulator builds are frequently unsigned (any `CODE_SIGNING_ALLOWED=NO`
        // build is), and an unsigned process carries no iCloud container, so
        // CKContainer would take the app down at launch.
        return false
        #else
        // Device builds are always signed, and the entitlements file lists the
        // container for every target.
        return true
        #endif
    }

    private static var unentitledReason: String {
        #if targetEnvironment(simulator)
        return "iCloud sync is off in the Simulator; boards sync on a real device"
        #else
        return "Build is not signed with iCloud entitlements; sync is off"
        #endif
    }

    // MARK: - Local change intake

    private func enqueueSave(_ id: Dashboard.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: id))])
    }

    private func enqueueDelete(_ id: Dashboard.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(for: id))])
    }

    private func recordID(for id: Dashboard.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    // MARK: - State serialization

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(serialization) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: - Record mapping

    private func makeRecord(for dashboard: Dashboard) -> CKRecord? {
        let record = CKRecord(recordType: Self.recordType,
                              recordID: recordID(for: dashboard.id))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(dashboard) else { return nil }
        record[Self.payloadKey] = payload as NSData
        return record
    }

    private func decodeDashboard(from record: CKRecord) -> Dashboard? {
        guard let payload = record[Self.payloadKey] as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Dashboard.self, from: payload)
    }
}

extension CloudSyncEngine: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveStateSerialization(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signOut, .switchAccounts:
                state = .unavailable("iCloud account changed")
            case .signIn:
                state = .idle
                start()
            default:
                state = .idle
            }

        case .fetchedRecordZoneChanges(let changes):
            lastSyncDate = Date()
            lastErrorMessage = nil
            for modification in changes.modifications {
                if let dashboard = decodeDashboard(from: modification.record) {
                    store.applyRemote(dashboard)
                }
            }
            for deletion in changes.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    store.applyRemoteDeletion(id: id)
                }
            }

        case .sentRecordZoneChanges(let sent):
            // Re-queue anything that conflicted; server record wins locally first.
            for failure in sent.failedRecordSaves {
                if failure.error.code == .serverRecordChanged,
                   let serverRecord = failure.error.serverRecord,
                   let remote = decodeDashboard(from: serverRecord) {
                    store.applyRemote(remote)
                    if let local = store.dashboard(id: remote.id), local.modifiedAt > remote.modifiedAt {
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    }
                } else {
                    // An upload that fails for any other reason is the one that
                    // strands every other device, so say so rather than retry
                    // in silence.
                    lastErrorMessage = Self.describe(failure.error)
                }
            }

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
        // Materialize records on the main actor; the batch's record provider
        // closure runs outside our isolation.
        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            guard case .saveRecord(let recordID) = change else { continue }
            if let id = UUID(uuidString: recordID.recordName),
               let dashboard = store.dashboard(id: id),
               let record = makeRecord(for: dashboard) {
                recordsByID[recordID] = record
            } else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        }
        let snapshot = recordsByID
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            snapshot[recordID]
        }
    }
}
