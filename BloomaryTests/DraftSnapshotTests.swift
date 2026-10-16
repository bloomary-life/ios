import Foundation
import Testing
@testable import Bloomary

struct DraftSnapshotTests {
    @Test
    func backgroundWritesPersistLatestImageSnapshotForReload() async throws {
        let suite = makeSuite()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let repository = UserDefaultsDraftRepository(key: testKey, defaults: suite.defaults)
        var draft = Draft(body: "First version", imageData: Data(repeating: 42, count: 1_000_000), imageFilename: "image.jpg", imageMimeType: "image/jpeg", createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 60))
        repository.saveSnapshot(DraftSnapshot(drafts: [draft], ownerID: "member-1"), ownerID: "member-1")
        draft.body = "Latest version"
        repository.saveSnapshot(DraftSnapshot(drafts: [draft], ownerID: "member-1"), ownerID: "member-1")

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let data = suite.defaults.data(forKey: "\(testKey).member-1"),
               let snapshot = try? JSONDecoder.app.decode(DraftSnapshot.self, from: data),
               snapshot.drafts.first?.body == "Latest version" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reloaded = UserDefaultsDraftRepository(key: testKey, defaults: suite.defaults).loadSnapshot(ownerID: "member-1")
        #expect(reloaded.drafts == [draft])
    }

    @Test
    func snapshotRoundTripsThroughRepository() {
        let repository = makeRepository()
        let draft = Draft(
            id: UUID(),
            body: "Hello LinkedIn",
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 60)
        )
        let syncedAt = Date(timeIntervalSince1970: 100)
        repository.saveSnapshot(
            DraftSnapshot(drafts: [draft], ownerID: "member-1", lastSuccessfulSyncAt: syncedAt),
            ownerID: "member-1"
        )

        let loaded = repository.loadSnapshot(ownerID: "member-1")

        #expect(loaded.drafts == [draft])
        #expect(loaded.ownerID == "member-1")
        #expect(loaded.lastSuccessfulSyncAt == syncedAt)
        #expect(loaded.schemaVersion == DraftSnapshot.currentSchemaVersion)
    }

    @Test
    func legacyBareDraftArrayPayloadMigratesToSnapshot() {
        let suite = makeSuite()
        let repository = UserDefaultsDraftRepository(key: testKey, defaults: suite.defaults)
        let draft = Draft(
            id: UUID(),
            body: "Legacy draft",
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 60)
        )
        let legacyData = try! JSONEncoder.app.encode([draft])
        suite.defaults.set(legacyData, forKey: "\(testKey).member-1")

        let loaded = repository.loadSnapshot(ownerID: "member-1")

        #expect(loaded.drafts == [draft])
        #expect(loaded.schemaVersion == DraftSnapshot.currentSchemaVersion)
        #expect(loaded.lastSuccessfulSyncAt == nil)
    }

    @Test
    func corruptCacheFallsBackToEmptyDrafts() {
        let suite = makeSuite()
        let repository = UserDefaultsDraftRepository(key: testKey, defaults: suite.defaults)
        suite.defaults.set(Data("not json".utf8), forKey: "\(testKey).member-1")

        let loaded = repository.loadSnapshot(ownerID: "member-1")

        #expect(loaded.drafts.isEmpty)
        #expect(repository.loadDrafts(ownerID: "member-1").isEmpty)
    }

    @Test
    func saveDraftsPreservesLastSuccessfulSyncAt() {
        let repository = makeRepository()
        let syncedAt = Date(timeIntervalSince1970: 200)
        repository.saveSnapshot(
            DraftSnapshot(drafts: [], ownerID: "member-1", lastSuccessfulSyncAt: syncedAt),
            ownerID: "member-1"
        )

        repository.saveDrafts([Draft(id: UUID(), body: "New", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))], ownerID: "member-1")

        let loaded = repository.loadSnapshot(ownerID: "member-1")
        #expect(loaded.drafts.map(\.body) == ["New"])
        #expect(loaded.lastSuccessfulSyncAt == syncedAt)
    }

    @Test
    func missingCacheReturnsEmptySnapshot() {
        let repository = makeRepository()

        let loaded = repository.loadSnapshot(ownerID: "member-1")

        #expect(loaded.drafts.isEmpty)
        #expect(loaded.ownerID == "member-1")
        #expect(loaded.lastSuccessfulSyncAt == nil)
    }

    private let testKey = "test.drafts"

    private func makeRepository() -> UserDefaultsDraftRepository {
        UserDefaultsDraftRepository(key: testKey, defaults: makeSuite().defaults)
    }

    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "DraftSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }
}
