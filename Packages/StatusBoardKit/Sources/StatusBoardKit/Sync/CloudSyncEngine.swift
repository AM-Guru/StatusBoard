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

    @ObservationIgnored private let store: DashboardStore
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var startTask: Task<Void, Never>?
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
            state = .idle
            lastSyncDate = Date()
        }
        try? await engine.fetchChanges()
        try? await engine.sendChanges()
    }

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
