import Foundation

/// Versioned local cache envelope for drafts. Persisted behind `DraftRepository`
/// so a later SQLite/Core Data swap requires no UI changes.
struct DraftSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var drafts: [Draft]
    let ownerID: String?
    let loadedAt: Date
    var lastSuccessfulSyncAt: Date?
    var syncedIDs: Set<Draft.ID>?
    let schemaVersion: Int

    init(
        drafts: [Draft] = [],
        ownerID: String? = nil,
        loadedAt: Date = Date(),
        lastSuccessfulSyncAt: Date? = nil,
        syncedIDs: Set<Draft.ID>? = nil,
        schemaVersion: Int = DraftSnapshot.currentSchemaVersion
    ) {
        self.drafts = drafts
        self.ownerID = ownerID
        self.loadedAt = loadedAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.syncedIDs = syncedIDs
        self.schemaVersion = schemaVersion
    }

    static func empty(ownerID: String?) -> DraftSnapshot {
        DraftSnapshot(drafts: [], ownerID: ownerID)
    }
}
