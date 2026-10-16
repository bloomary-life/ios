import Foundation
import OSLog

protocol DraftRepository {
    func loadDrafts(ownerID: String?) -> [Draft]
    func saveDrafts(_ drafts: [Draft], ownerID: String?)
    func deleteDrafts(ownerID: String?)
    func loadSnapshot(ownerID: String?) -> DraftSnapshot
    func saveSnapshot(_ snapshot: DraftSnapshot, ownerID: String?)
    func loadSyncMutations(ownerID: String) -> [DraftSyncMutation]
    func saveSyncMutations(_ mutations: [DraftSyncMutation], ownerID: String)
    func deleteSyncMutations(ownerID: String)
}

/// Default snapshot bridge so existing repositories (and test doubles) keep
/// working; the durable store overrides these with the versioned envelope.
extension DraftRepository {
    func loadSnapshot(ownerID: String?) -> DraftSnapshot {
        DraftSnapshot(drafts: loadDrafts(ownerID: ownerID), ownerID: ownerID)
    }

    func saveSnapshot(_ snapshot: DraftSnapshot, ownerID: String?) {
        saveDrafts(snapshot.drafts, ownerID: ownerID)
    }

    func loadSyncMutations(ownerID: String) -> [DraftSyncMutation] {
        []
    }

    func saveSyncMutations(_ mutations: [DraftSyncMutation], ownerID: String) {}

    func deleteSyncMutations(ownerID: String) {}
}

// The lock protects in-memory caches; writeQueue serializes durable writes.
final class UserDefaultsDraftRepository: DraftRepository, @unchecked Sendable {
    static let failureNotification = Notification.Name("BloomaryDraftCacheFailure")
    private let logger = Logger(subsystem: "com.dailymind.bloomary", category: "DraftCache")
    private let lock = NSRecursiveLock()
    private var snapshots: [String: DraftSnapshot] = [:]
    private var queues: [String: [DraftSyncMutation]] = [:]
    private let key: String
    private let defaults: UserDefaults
    private let writeQueue = DispatchQueue(label: "life.bloomary.UserDefaultsDraftRepository", qos: .utility)

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    func loadDrafts(ownerID: String?) -> [Draft] {
        loadSnapshot(ownerID: ownerID).drafts
    }

    func saveDrafts(_ drafts: [Draft], ownerID: String?) {
        var snapshot = loadSnapshot(ownerID: ownerID)
        snapshot.drafts = drafts
        saveSnapshot(snapshot, ownerID: ownerID)
    }

    func loadSnapshot(ownerID: String?) -> DraftSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = scopedKey(ownerID: ownerID)
        if let cached = snapshots[cacheKey] { return cached }
        guard let data = defaults.data(forKey: cacheKey) else {
            return .empty(ownerID: ownerID)
        }
        // Current format: versioned snapshot envelope.
        if let snapshot = try? JSONDecoder.app.decode(DraftSnapshot.self, from: data),
           snapshot.schemaVersion <= DraftSnapshot.currentSchemaVersion {
            snapshots[cacheKey] = snapshot
            return snapshot
        }
        // Migration point: pre-snapshot payloads were a bare [Draft] array.
        if let drafts = try? JSONDecoder.app.decode([Draft].self, from: data) {
            let snapshot = DraftSnapshot(drafts: drafts, ownerID: ownerID)
            snapshots[cacheKey] = snapshot
            return snapshot
        }
        quarantine(data, key: cacheKey)
        return .empty(ownerID: ownerID)
    }

    func saveSnapshot(_ snapshot: DraftSnapshot, ownerID: String?) {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = scopedKey(ownerID: ownerID)
        snapshots[cacheKey] = snapshot
        writeQueue.async { [self] in
            do { defaults.set(try JSONEncoder.app.encode(snapshot), forKey: cacheKey) }
            catch { reportFailure() }
        }
    }

    func deleteDrafts(ownerID: String?) {
        let key = scopedKey(ownerID: ownerID)
        lock.lock()
        defer { lock.unlock() }
        snapshots[key] = .empty(ownerID: ownerID)
        writeQueue.async { [self] in defaults.removeObject(forKey: key) }
    }

    func loadSyncMutations(ownerID: String) -> [DraftSyncMutation] {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = syncQueueKey(ownerID: ownerID)
        if let cached = queues[cacheKey] { return cached }
        guard let data = defaults.data(forKey: cacheKey) else { return [] }
        do {
            let drafts = loadSnapshot(ownerID: ownerID).drafts
            let mutations = try JSONDecoder.app.decode([DraftSyncMutation].self, from: data).map { mutation in
                guard var draft = mutation.draft, draft.imageData == nil,
                      let cached = drafts.first(where: { $0.id == draft.id }),
                      cached.updatedAt == draft.updatedAt else { return mutation }
                draft.imageData = cached.imageData
                return mutation.replacingDraft(draft)
            }
            queues[cacheKey] = mutations
            return mutations
        } catch {
            quarantine(data, key: cacheKey)
            return []
        }
    }

    func saveSyncMutations(_ mutations: [DraftSyncMutation], ownerID: String) {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = syncQueueKey(ownerID: ownerID)
        queues[cacheKey] = mutations
        let savedDrafts = snapshots[scopedKey(ownerID: ownerID)]?.drafts ?? []
        writeQueue.async { [self] in
            do {
                let lightweight = mutations.map { mutation in
                    guard var draft = mutation.draft,
                          savedDrafts.contains(where: { $0.id == draft.id && $0.updatedAt == draft.updatedAt && $0.imageData == draft.imageData }) else { return mutation }
                    draft.imageData = nil
                    return mutation.replacingDraft(draft)
                }
                defaults.set(try JSONEncoder.app.encode(lightweight), forKey: cacheKey)
            } catch { reportFailure() }
        }
    }

    func deleteSyncMutations(ownerID: String) {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = syncQueueKey(ownerID: ownerID)
        queues[cacheKey] = []
        writeQueue.async { [self] in defaults.removeObject(forKey: cacheKey) }
    }

    private func quarantine(_ data: Data, key: String) {
        defaults.set(data, forKey: "\(key).recovery.\(UUID().uuidString)")
        reportFailure()
    }

    private func reportFailure() {
        logger.error("Draft cache could not be loaded or written; recovery data retained.")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.failureNotification, object: nil)
        }
    }

    private func scopedKey(ownerID: String?) -> String {
        "\(key).\(ownerID ?? "signed-out")"
    }

    private func syncQueueKey(ownerID: String) -> String {
        "\(key).syncQueue.\(ownerID)"
    }
}
