import Testing
import Foundation
@testable import Bloomary

@MainActor
struct DraftStoreTests {
    @Test
    func savingEmptyDraftDoesNotPersist() {
        let repository = InMemoryDraftRepository()
        var trackedEvents: [AppTelemetryEvent] = []
        let store = DraftStore(draftRepository: repository, telemetry: { event, _ in
            trackedEvents.append(event)
        })

        store.editorText = "   "
        store.saveCurrentDraft()

        #expect(store.drafts.isEmpty)
        #expect(repository.savedDrafts(ownerID: nil).isEmpty)
        #expect(store.statusMessage == "Draft is empty")
        #expect(trackedEvents.isEmpty)
    }

    @Test
    func savingDraftTrimsBodyAndPersists() {
        let repository = InMemoryDraftRepository()
        var trackedEvents: [AppTelemetryEvent] = []
        let store = DraftStore(draftRepository: repository, telemetry: { event, _ in
            trackedEvents.append(event)
        })

        store.editorText = "  Hello LinkedIn  "
        store.saveCurrentDraft()

        #expect(store.drafts.map(\.body) == ["Hello LinkedIn"])
        #expect(repository.savedDrafts(ownerID: nil).map(\.body) == ["Hello LinkedIn"])
        #expect(store.statusMessage == "Draft saved")
        #expect(trackedEvents == [.draftSaved])
    }

    @Test
    func savingDraftPersistsImageDataAndReopensIt() {
        let repository = InMemoryDraftRepository()
        let store = DraftStore(draftRepository: repository)
        let imageData = Data([1, 2, 3])

        store.editorText = "Draft with image"
        store.editorImageData = imageData
        store.editorImageFilename = "image.jpg"
        store.editorImageMimeType = "image/jpeg"
        store.saveCurrentDraft()
        store.startNewPost()
        store.openDraft(store.drafts[0])

        #expect(repository.savedDrafts(ownerID: nil).first?.imageData == imageData)
        #expect(repository.savedDrafts(ownerID: nil).first?.imageFilename == "image.jpg")
        #expect(repository.savedDrafts(ownerID: nil).first?.imageMimeType == "image/jpeg")
        #expect(store.editorImageData == imageData)
        #expect(store.editorImageFilename == "image.jpg")
        #expect(store.editorImageMimeType == "image/jpeg")
    }

    @Test
    func savingImageOnlyDraftPersists() {
        let repository = InMemoryDraftRepository()
        let store = DraftStore(draftRepository: repository)
        let imageData = Data([4, 5, 6])

        store.editorText = "   "
        store.editorImageData = imageData
        store.saveCurrentDraft()

        #expect(store.drafts.count == 1)
        #expect(repository.savedDrafts(ownerID: nil).first?.imageData == imageData)
        #expect(store.statusMessage == "Draft saved")
    }

    @Test
    func savingOpenedDraftUpdatesExistingDraft() {
        let draft = Draft(body: "Old body")
        let repository = InMemoryDraftRepository()
        repository.setDrafts([draft], ownerID: nil)
        let store = DraftStore(draftRepository: repository)

        store.openDraft(draft)
        store.editorText = "Updated body"
        store.saveCurrentDraft()

        #expect(store.drafts.count == 1)
        #expect(store.drafts.first?.id == draft.id)
        #expect(store.drafts.first?.body == "Updated body")
        #expect(repository.savedDrafts(ownerID: nil).count == 1)
        #expect(repository.savedDrafts(ownerID: nil).first?.id == draft.id)
    }

    @Test
    func trialEditsEveryDraftUpToFifty() {
        let drafts = (0..<7).map { Draft(body: "Draft \($0)", updatedAt: Date().addingTimeInterval(TimeInterval(-$0))) }
        let repository = InMemoryDraftRepository()
        repository.setDrafts(drafts, ownerID: nil)
        let store = DraftStore(draftRepository: repository)
        store.setEntitlement(isPro: false, postCount: 0, tier: .trial)

        let oldest = drafts[6]
        store.openDraft(oldest)
        store.editorText = "Edited oldest"

        #expect(store.maxDrafts == 50)
        #expect(store.canEdit(oldest))
        #expect(store.saveCurrentDraft())
        #expect(store.drafts.first?.body == "Edited oldest")
    }

    @Test
    func lapsedSavesNewDraftUnderFiveThenFreezesIt() {
        let repository = InMemoryDraftRepository()
        repository.setDrafts([Draft(body: "Old")], ownerID: nil)
        let store = DraftStore(draftRepository: repository)
        store.setEntitlement(isPro: false, postCount: 0, tier: .lapsed)

        store.editorText = "New while lapsed"
        #expect(store.saveCurrentDraft())
        #expect(store.statusMessage == "Saved. Without a plan, drafts can't be edited, deleted, or published.")
        let saved = store.drafts[0]

        store.editorText = "Edited while lapsed"
        #expect(!store.saveCurrentDraft())
        store.deleteDraft(saved)
        #expect(store.drafts.map(\.body) == ["New while lapsed", "Old"])
    }

    @Test
    func lapsedAtFiveDraftsCannotCreate() {
        let repository = InMemoryDraftRepository()
        repository.setDrafts((0..<5).map { Draft(body: "Draft \($0)") }, ownerID: nil)
        let store = DraftStore(draftRepository: repository)
        store.setEntitlement(isPro: false, postCount: 0, tier: .lapsed)

        store.editorText = "One more"

        #expect(!store.saveCurrentDraft())
        #expect(store.drafts.count == 5)
        #expect(store.statusMessage == "You've reached 5 drafts without a plan.")
    }

    @Test
    func clearingOpenedDraftSavesDraftAndEmptiesEditor() {
        let draft = Draft(body: "Old body")
        let repository = InMemoryDraftRepository()
        repository.setDrafts([draft], ownerID: nil)
        let store = DraftStore(draftRepository: repository)

        store.openDraft(draft)
        store.editorText = "Edited before clear"
        store.saveOpenedDraftAndClearEditor()

        #expect(store.editorText.isEmpty)
        #expect(store.statusMessage == nil)
        #expect(store.drafts.count == 1)
        #expect(store.drafts.first?.id == draft.id)
        #expect(store.drafts.first?.body == "Edited before clear")
        #expect(repository.savedDrafts(ownerID: nil).first?.body == "Edited before clear")
    }

    @Test
    func clearingNewPostDoesNotCreateDraft() {
        let repository = InMemoryDraftRepository()
        let store = DraftStore(draftRepository: repository)

        store.editorText = "New unsaved post"
        store.saveOpenedDraftAndClearEditor()

        #expect(store.editorText.isEmpty)
        #expect(store.statusMessage == nil)
        #expect(store.drafts.isEmpty)
        #expect(repository.savedDrafts(ownerID: nil).isEmpty)
    }

    @Test
    func startingNewPostClearsOpenedDraft() {
        let draft = Draft(body: "Old body")
        let repository = InMemoryDraftRepository()
        repository.setDrafts([draft], ownerID: nil)
        let store = DraftStore(draftRepository: repository)

        store.openDraft(draft)
        store.editorText = "Unsaved edit"
        store.startNewPost()
        store.editorText = "New post"
        store.saveCurrentDraft()

        #expect(store.drafts.count == 2)
        #expect(store.drafts.first?.body == "New post")
        #expect(store.drafts.last?.body == "Old body")
    }

    @Test
    func deletingPostedDraftIfSavedRemovesOpenedDraft() {
        let openedDraft = Draft(body: "Opened body")
        let otherDraft = Draft(body: "Other body")
        let repository = InMemoryDraftRepository()
        repository.setDrafts([openedDraft, otherDraft], ownerID: nil)
        let store = DraftStore(draftRepository: repository)

        store.openDraft(openedDraft)
        store.editorText = "Edited body"
        store.deletePostedDraftIfSaved()

        #expect(store.editorText == "Edited body")
        #expect(store.drafts.map(\.id) == [otherDraft.id])
        #expect(repository.savedDrafts(ownerID: nil).map(\.id) == [otherDraft.id])
    }

    @Test
    func switchingOwnerLoadsOnlyThatOwnersDrafts() {
        let repository = InMemoryDraftRepository()
        repository.setDrafts([Draft(body: "User A draft")], ownerID: "user-a")
        repository.setDrafts([Draft(body: "User B draft")], ownerID: "user-b")
        let store = DraftStore(draftRepository: repository)

        store.setOwnerID("user-a")
        #expect(store.drafts.map(\.body) == ["User A draft"])

        store.setOwnerID("user-b")
        #expect(store.drafts.map(\.body) == ["User B draft"])
    }

    @Test
    func signingInMigratesSignedOutDraftsToMember() {
        let signedOutDraft = Draft(body: "Draft before login")
        let signedInDraft = Draft(body: "Existing member draft")
        let repository = InMemoryDraftRepository()
        repository.setDrafts([signedOutDraft], ownerID: nil)
        repository.setDrafts([signedInDraft], ownerID: "member-1")
        let store = DraftStore(draftRepository: repository)

        store.setOwnerID("member-1")

        #expect(store.drafts.map(\.body).contains("Draft before login"))
        #expect(store.drafts.map(\.body).contains("Existing member draft"))
        #expect(repository.savedDrafts(ownerID: "member-1").map(\.body).contains("Draft before login"))
        #expect(repository.savedDrafts(ownerID: nil).isEmpty)
    }

    @Test
    func coldLaunchHonorsSavedReductionAndResumesWhenEnabled() async throws {
        let key = "DraftStoreTests.reduction.\(UUID().uuidString)"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let settings = SyncSettingsStore(key: key)
        let repository = InMemoryDraftRepository()
        let remote = Draft(body: "Remote draft")
        let syncService = InMemoryDraftSyncService(remoteDrafts: [remote])
        let store = DraftStore(draftRepository: repository, syncService: syncService, syncSettingsStore: settings)
        defer { store.setSession(nil) }

        store.setSession(linkedInToken(memberID: "user-a"))
        #expect(store.syncStatus == .disabled)
        #expect(store.drafts.isEmpty)
        #expect(await syncService.listRequestCount() == 0)

        settings.isDataReductionEnabled = false
        settings.save()
        try await waitFor { store.drafts.first?.id == remote.id }
        #expect(store.drafts.first?.body == "Remote draft")
        #expect(await syncService.listRequestCount() > 0)
    }

    @Test
    func settingSessionPullsNewerRemoteDrafts() async throws {
        let local = Draft(id: UUID(), body: "Local old", updatedAt: Date(timeIntervalSince1970: 10))
        let remote = Draft(id: local.id, body: "Remote newer", updatedAt: Date(timeIntervalSince1970: 20))
        let repository = InMemoryDraftRepository()
        repository.setDrafts([local], ownerID: "user-a")
        let syncService = InMemoryDraftSyncService(remoteDrafts: [remote])
        let store = DraftStore(draftRepository: repository, syncService: syncService)

        store.setSession(linkedInToken(memberID: "user-a"))
        try await waitFor { store.drafts.first?.body == "Remote newer" }

        #expect(repository.savedDrafts(ownerID: "user-a").first?.body == "Remote newer")
    }

    @Test
    func settingSessionSurvivesRemoteDraftsSharingAnID() async throws {
        // The server keys drafts by the raw draftId string, so "ABC…" and "abc…" are two rows
        // that decode to one UUID; sync must keep one instead of trapping on the duplicate.
        let id = UUID()
        let older = Draft(id: id, body: "Remote older", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = Draft(id: id, body: "Remote newer", updatedAt: Date(timeIntervalSince1970: 20))
        let repository = InMemoryDraftRepository()
        let syncService = InMemoryDraftSyncService(remoteDrafts: [newer, older])
        let store = DraftStore(draftRepository: repository, syncService: syncService)
        defer { store.setSession(nil) }

        store.setSession(linkedInToken(memberID: "user-a"))
        try await waitFor { store.drafts.first?.id == id }

        #expect(store.drafts.count == 1)
    }

    @Test
    func savingDraftPushesRemoteCopy() async throws {
        let repository = InMemoryDraftRepository()
        let syncService = InMemoryDraftSyncService()
        let store = DraftStore(draftRepository: repository, syncService: syncService)

        store.setSession(linkedInToken(memberID: "user-a"))
        store.editorText = "Synced body"
        store.saveCurrentDraft()
        try await waitFor { await syncService.upsertedBodies() == ["Synced body"] }

        #expect(repository.savedSyncMutations(ownerID: "user-a").isEmpty)
    }

    @Test
    func lapsedPullsArchiveAndPushesOnlyNewDrafts() async throws {
        let stored = Draft(body: "Remote stored")
        let repository = InMemoryDraftRepository()
        let syncService = InMemoryDraftSyncService(remoteDrafts: [stored])
        let store = DraftStore(draftRepository: repository, syncService: syncService)

        store.setSession(linkedInToken(memberID: "user-a"))
        try await waitFor { store.drafts.map(\.body) == ["Remote stored"] && store.syncStatus == .synced }
        store.setEntitlement(isPro: false, postCount: 0, tier: .lapsed)
        var edited = stored
        edited.body = "Edited before lapse"
        repository.saveSyncMutations([DraftSyncMutation(ownerID: "user-a", operation: .upsert, draftID: stored.id, draft: edited)], ownerID: "user-a")

        store.editorText = "New while lapsed"
        #expect(store.saveCurrentDraft())
        try await waitFor { repository.savedSyncMutations(ownerID: "user-a").isEmpty }

        #expect(await syncService.upsertedBodies() == ["New while lapsed"])
        #expect(await syncService.listRequestCount() > 0)
    }

    @Test
    func failedSyncKeepsMutationForLaterRetry() async throws {
        let repository = InMemoryDraftRepository()
        let syncService = InMemoryDraftSyncService(error: DraftSyncTestError.offline)
        let store = DraftStore(draftRepository: repository, syncService: syncService)

        store.setSession(linkedInToken(memberID: "user-a"))
        store.editorText = "Queued body"
        store.saveCurrentDraft()
        try await waitFor { repository.savedSyncMutations(ownerID: "user-a").first?.lastError != nil }

        #expect(store.syncStatus == .failed)
        #expect(repository.savedSyncMutations(ownerID: "user-a").map(\.operation) == [.upsert])
    }

    @Test
    func parkedMutationRetriesAfterExplicitRetry() async throws {
        let repository = InMemoryDraftRepository()
        let syncService = InMemoryDraftSyncService(error: DraftSyncTestError.offline)
        let store = DraftStore(draftRepository: repository, syncService: syncService)

        var parked = DraftSyncMutation(ownerID: "user-a", operation: .delete, draftID: UUID())
        parked.attemptCount = DraftSyncPolicy.maxRetryAttempts
        parked.nextAttemptAt = .distantFuture
        parked.lastError = "offline"
        repository.saveSyncMutations([parked], ownerID: "user-a")

        store.setSession(linkedInToken(memberID: "user-a"))
        #expect(repository.savedSyncMutations(ownerID: "user-a").first.map(DraftSyncPolicy.isParked) == true)
        store.retrySync()

        try await waitFor {
            guard let mutation = repository.savedSyncMutations(ownerID: "user-a").first else { return false }
            return mutation.attemptCount > 0 && !DraftSyncPolicy.isParked(mutation)
        }
        #expect(store.syncStatus == .failed)
    }

    @Test
    func deletingAccountDataRemovesSignedInAndSignedOutDrafts() {
        let repository = InMemoryDraftRepository()
        repository.setDrafts([Draft(body: "Signed-in draft")], ownerID: "user-a")
        repository.setDrafts([Draft(body: "Signed-out draft")], ownerID: nil)
        let store = DraftStore(draftRepository: repository)

        store.setOwnerID("user-a")
        store.openDraft(store.drafts[0])
        store.editorText = "Unsaved account text"
        store.deleteAccountData(ownerID: "user-a")

        #expect(store.drafts.isEmpty)
        #expect(store.editorText.isEmpty)
        #expect(repository.savedDrafts(ownerID: "user-a").isEmpty)
        #expect(repository.savedDrafts(ownerID: nil).isEmpty)
    }
}

private final class InMemoryDraftRepository: DraftRepository {
    private var draftsByOwnerID: [String: [Draft]] = [:]
    private var mutationsByOwnerID: [String: [DraftSyncMutation]] = [:]

    func loadDrafts(ownerID: String?) -> [Draft] {
        draftsByOwnerID[key(ownerID)] ?? []
    }

    func saveDrafts(_ drafts: [Draft], ownerID: String?) {
        draftsByOwnerID[key(ownerID)] = drafts
    }

    func deleteDrafts(ownerID: String?) {
        draftsByOwnerID.removeValue(forKey: key(ownerID))
    }

    func loadSyncMutations(ownerID: String) -> [DraftSyncMutation] {
        mutationsByOwnerID[ownerID] ?? []
    }

    func saveSyncMutations(_ mutations: [DraftSyncMutation], ownerID: String) {
        mutationsByOwnerID[ownerID] = mutations
    }

    func deleteSyncMutations(ownerID: String) {
        mutationsByOwnerID.removeValue(forKey: ownerID)
    }

    func setDrafts(_ drafts: [Draft], ownerID: String?) {
        draftsByOwnerID[key(ownerID)] = drafts
    }

    func savedDrafts(ownerID: String?) -> [Draft] {
        draftsByOwnerID[key(ownerID)] ?? []
    }

    func savedSyncMutations(ownerID: String) -> [DraftSyncMutation] {
        mutationsByOwnerID[ownerID] ?? []
    }

    private func key(_ ownerID: String?) -> String {
        ownerID ?? "signed-out"
    }
}

private func linkedInToken(memberID: String) -> LinkedInToken {
    LinkedInToken(
        accessToken: "access-token",
        tokenType: nil,
        scope: nil,
        expiresIn: nil,
        profile: LinkedInProfile(
            memberID: memberID,
            name: "Test User",
            pictureURL: nil,
            email: nil,
            headline: nil,
            localizedHeadline: nil
        ),
        connectedAt: Date(timeIntervalSince1970: 0)
    )
}

private func waitFor(
    timeout: Duration = .seconds(1),
    condition: @escaping () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while !Task.isCancelled {
        if await condition() { return }
        if start.duration(to: ContinuousClock.now) > timeout { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor InMemoryDraftSyncService: DraftSyncing {
    private var remoteDrafts: [Draft]
    private var upserts: [Draft] = []
    private var listRequests = 0
    private let error: Error?

    init(remoteDrafts: [Draft] = [], error: Error? = nil) {
        self.remoteDrafts = remoteDrafts
        self.error = error
    }

    func listRequestCount() -> Int { listRequests }

    func listDrafts(memberID: String, accessToken: String) async throws -> [Draft] {
        listRequests += 1
        if let error { throw error }
        return remoteDrafts
    }

    func upsertDraft(_ draft: Draft, memberID: String, accessToken: String) async throws -> Draft {
        if let error { throw error }
        upserts.append(draft)
        remoteDrafts.removeAll { $0.id == draft.id }
        remoteDrafts.append(draft)
        return draft
    }

    func deleteDraft(id: Draft.ID, memberID: String, accessToken: String) async throws {
        if let error { throw error }
        remoteDrafts.removeAll { $0.id == id }
    }

    func upsertedBodies() -> [String] {
        upserts.map(\.body)
    }
}

private enum DraftSyncTestError: LocalizedError {
    case offline

    var errorDescription: String? { "offline" }
}
