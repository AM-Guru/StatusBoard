import Foundation
import CloudKit
#if os(macOS)
import Security
#endif

/// Syncs dashboards through the user's private CloudKit database using
/// CKSyncEngine. Each dashboard is one record carrying its JSON payload.
@MainActor
public final class CloudSyncEngine: NSObject {
    public enum State: Equatable {
        case idle
        case syncing
        case unavailable(String)
    }

    public private(set) var state: State = .idle

    private let store: DashboardStore
    private var engine: CKSyncEngine?
    private let zoneID = CKRecordZone.ID(zoneName: "StatusBoards")
    private let stateURL: URL

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
        guard engine == nil else { return }
        guard Self.processHasCloudKitEntitlement() else {
            state = .unavailable("Build is not signed with iCloud entitlements; sync is off")
            return
        }
        guard FileManager.default.ubiquityIdentityToken != nil else {
            state = .unavailable("Sign in to iCloud to sync dashboards")
            return
        }
        let container = CKContainer(identifier: SBIdentifiers.cloudContainer)
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadStateSerialization(),
            delegate: self)
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        // Push everything we have locally; CloudKit dedupes by record change tag.
        for dashboard in store.dashboards {
            enqueueSave(dashboard.id)
        }
    }

    public func syncNow() async {
        guard let engine else { return }
        state = .syncing
        defer { state = .idle }
        try? await engine.fetchChanges()
        try? await engine.sendChanges()
    }

    /// CKContainer raises an uncatchable NSException when the process lacks
    /// iCloud entitlements (common in unsigned development builds), so check
    /// before touching CloudKit.
    private static func processHasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-services" as CFString, nil)
        return value != nil
        #else
        // iOS/tvOS builds run through Xcode always embed the entitlements file.
        return true
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
            default:
                state = .idle
            }

        case .fetchedRecordZoneChanges(let changes):
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
