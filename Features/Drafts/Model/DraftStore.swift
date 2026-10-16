import Foundation
import OSLog
import Combine

enum DraftSyncStatus: Equatable {
    case localOnly
    case pending
    case synced
    case failed
    case disabled

    var message: String {
        switch self {
        case .localOnly:
            return "Saved locally"
        case .pending:
            return "Sync pending"
        case .synced:
            return "Synced"
        case .failed:
            return "Sync failed. Retry to resume."
        case .disabled:
            return "Sync disabled"
        }
    }
}

@MainActor
final class DraftStore: ObservableObject {
    @Published var editorText: String
    @Published var editorImageData: Data?
    @Published var editorImageFilename: String?
    @Published var editorImageMimeType: String?
    @Published private(set) var drafts: [Draft]
    @Published private(set) var scheduledPosts: [ScheduledPostResult] = []
    @Published var statusMessage: String?
    @Published private(set) var syncStatus: DraftSyncStatus = .localOnly
    @Published private(set) var isPro = false
    @Published private(set) var postCount = 0

    @Published private(set) var maxDraftBodyRunes = 4000
    @Published private(set) var maxImageBytes = 5 * 1024 * 1024
    @Published private(set) var accessUntil: Date?
    @Published private(set) var subscriptionSource: String?
    /// nil until the first entitlement response.
    @Published private(set) var tier: EntitlementTier?
    /// trial or pro. `isPro` is false during trial (`docs/product/tiers.md`).
    var hasPlanAccess: Bool { tier?.hasAccess ?? false }
    var isLapsed: Bool { tier == .lapsed }
    var maxDrafts: Int { hasPlanAccess ? 50 : 5 }
    var isDraftLimitReached: Bool { drafts.count >= maxDrafts }
    var isEditingExistingDraft: Bool { editingDraftID != nil }
    var draftCountText: String { "\(drafts.count)/\(maxDrafts)" }

    private var isDraftSyncEnabled: Bool { !accountWorkSuspended && !syncSettingsStore.isDataReductionEnabled }

    @Published private(set) var editingDraftID: Draft.ID?
    @Published var pendingDraft: Draft?
    private var editorsByOwner: [String: EditorSnapshot] = [:]

    struct EditorSnapshot: Equatable {
        let ownerID: String?
        let draftID: Draft.ID?
        let text: String
        let imageData: Data?
        let imageFilename: String?
        let imageMimeType: String?
    }

    var editorSnapshot: EditorSnapshot {
        EditorSnapshot(ownerID: ownerID, draftID: editingDraftID, text: editorText, imageData: editorImageData, imageFilename: editorImageFilename, imageMimeType: editorImageMimeType)
    }

    var hasUnsavedChanges: Bool {
        if let draft = drafts.first(where: { $0.id == editingDraftID }) {
            return draft.body != editorText || draft.imageData != editorImageData
        }
        return !DraftPolicy.trimmedBody(editorText).isEmpty || editorImageData != nil
    }

    private func restoreEditor(previousOwnerID: String?) {
        let previous = editorsByOwner[previousOwnerID ?? "signed-out"]
        let saved = editorsByOwner[ownerID ?? "signed-out"] ?? (previousOwnerID == nil && ownerID != nil ? previous : nil)
        startNewPost()
        guard let saved else { return }
        editorText = saved.text
        editingDraftID = saved.draftID
        editorImageData = saved.imageData
        editorImageFilename = saved.imageFilename
        editorImageMimeType = saved.imageMimeType
    }
    private var ownerID: String?
    private var isDrainingSyncQueue = false
    private var syncGeneration = 0
    private var accountWorkSuspended = false
    private var fetchTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var schedulingUploadTask: Task<Draft, Error>?
    private var settingsSubscription: AnyCancellable?
    private var cacheSubscription: AnyCancellable?
    private var lastScheduleResponseStartedAt = Date.distantPast
    private var localRevision = 0
    private var syncedIDs: Set<Draft.ID> = []
    private var lastSuccessfulSyncAt: Date?
    private var lastRemoteSyncAt = Date(timeIntervalSince1970: 0)
    private var periodicSyncTimer: Timer?

    private let draftRepository: DraftRepository
    private let syncService: DraftSyncing?
    private let syncSettingsStore: SyncSettingsStore
    private let telemetry: (AppTelemetryEvent, [String: String]) -> Void
    private let logger = Logger(subsystem: "com.dailymind.bloomary", category: "DraftStore")
    private var accessToken: String?

    init(
        draftRepository: DraftRepository,
        syncService: DraftSyncing? = nil,
        syncSettingsStore: SyncSettingsStore? = nil,
        telemetry: @escaping (AppTelemetryEvent, [String: String]) -> Void = { _, _ in }
    ) {
        self.draftRepository = draftRepository
        self.syncService = syncService
        self.syncSettingsStore = syncSettingsStore ?? SyncSettingsStore()
        self.telemetry = telemetry
        self.editorText = ""
        let snapshot = PerformanceSignposts.draftCacheLoad { draftRepository.loadSnapshot(ownerID: nil) }
        self.drafts = snapshot.drafts
        self.lastSuccessfulSyncAt = snapshot.lastSuccessfulSyncAt
        cacheSubscription = NotificationCenter.default.publisher(for: UserDefaultsDraftRepository.failureNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.statusMessage = "Draft cache failed. Recovery data was retained; keep this editor open and copy your work." }
        settingsSubscription = self.syncSettingsStore.$isDataReductionEnabled.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncGeneration += 1
                if self.isDraftSyncEnabled { self.drainSyncQueue(thenFetchRemote: true) }
                else { self.syncStatus = .disabled }
            }
        }
    }

    isolated deinit {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }

    func setSession(_ token: LinkedInToken?) {
        guard ownerID != token?.profile.memberID || accessToken != token?.accessToken else { return }
        syncGeneration += 1
        accountWorkSuspended = false
        let previousOwnerID = ownerID
        editorsByOwner[previousOwnerID ?? "signed-out"] = editorSnapshot
        ownerID = token?.profile.memberID
        accessToken = token?.accessToken
        localRevision += 1
        scheduledPosts = []
        lastScheduleResponseStartedAt = .distantPast
        setEntitlement(isPro: false, postCount: 0)
        let snapshot = PerformanceSignposts.draftCacheLoad { draftRepository.loadSnapshot(ownerID: ownerID) }
        syncedIDs = snapshot.syncedIDs ?? Set(snapshot.drafts.filter { $0.updatedAt <= (snapshot.lastSuccessfulSyncAt ?? .distantPast) }.map(\.id))
        lastSuccessfulSyncAt = snapshot.lastSuccessfulSyncAt
        if previousOwnerID == nil, let ownerID {
            let signedOutSnapshot = draftRepository.loadSnapshot(ownerID: nil)
            drafts = DraftPolicy.merge(local: snapshot.drafts, remote: signedOutSnapshot.drafts, maxDrafts: maxDrafts)
            persistDrafts(ownerID: ownerID)
            draftRepository.deleteDrafts(ownerID: nil)
        } else {
            drafts = snapshot.drafts
        }
        restoreEditor(previousOwnerID: previousOwnerID)
        drainSyncQueue(thenFetchRemote: true)
        updatePeriodicSync()
    }

    func importLegacyDrafts(_ legacy: [Draft]) {
        let existing = Set(drafts.map(\.id))
        let imported = legacy.filter { !existing.contains($0.id) }
        drafts += imported
        localRevision += 1
        persistDrafts(ownerID: ownerID)
        for draft in imported { enqueueSync(.upsert, draftID: draft.id, draft: draft) }
        statusMessage = "Recovered \(imported.count) older drafts in this environment."
    }

    @discardableResult
    func setScheduledPosts(_ posts: [ScheduledPostResult], credential: LinkedInPostCredential, requestedAt: Date = Date()) -> Bool {
        guard ownerID == credential.memberID, accessToken == credential.accessToken,
              requestedAt >= lastScheduleResponseStartedAt else { return false }
        lastScheduleResponseStartedAt = requestedAt
        scheduledPosts = posts
        return true
    }

    func setOwnerID(_ ownerID: String?) {
        guard self.ownerID != ownerID else { return }
        syncGeneration += 1
        accountWorkSuspended = false
        let previousOwnerID = self.ownerID
        editorsByOwner[previousOwnerID ?? "signed-out"] = editorSnapshot
        self.ownerID = ownerID
        accessToken = nil
        localRevision += 1
        scheduledPosts = []
        lastScheduleResponseStartedAt = .distantPast
        setEntitlement(isPro: false, postCount: 0)
        let snapshot = PerformanceSignposts.draftCacheLoad { draftRepository.loadSnapshot(ownerID: ownerID) }
        syncedIDs = snapshot.syncedIDs ?? Set(snapshot.drafts.filter { $0.updatedAt <= (snapshot.lastSuccessfulSyncAt ?? .distantPast) }.map(\.id))
        lastSuccessfulSyncAt = snapshot.lastSuccessfulSyncAt
        if previousOwnerID == nil, let ownerID {
            let signedOutSnapshot = draftRepository.loadSnapshot(ownerID: nil)
            drafts = DraftPolicy.merge(local: snapshot.drafts, remote: signedOutSnapshot.drafts, maxDrafts: maxDrafts)
            persistDrafts(ownerID: ownerID)
            draftRepository.deleteDrafts(ownerID: nil)
        } else {
            drafts = snapshot.drafts
        }
        restoreEditor(previousOwnerID: previousOwnerID)
        syncStatus = ownerID == nil ? .localOnly : .pending
        updatePeriodicSync()
    }

    private func rearmParkedSyncMutations() {
        guard let ownerID else { return }
        let queue = draftRepository.loadSyncMutations(ownerID: ownerID)
        let rearmed = DraftSyncPolicy.resetParked(in: queue)
        if rearmed != queue {
            draftRepository.saveSyncMutations(rearmed, ownerID: ownerID)
        }
    }

    func startNewPost() {
        editorText = ""
        editorImageData = nil
        editorImageFilename = nil
        editorImageMimeType = nil
        editingDraftID = nil
        statusMessage = nil
    }

    @discardableResult
    func saveCurrentDraft() -> Bool {
        let body = DraftPolicy.trimmedBody(editorText)
        guard body.unicodeScalars.count <= maxDraftBodyRunes else {
            statusMessage = "Draft exceeds the \(maxDraftBodyRunes) character sync limit. Shorten it before saving."
            return false
        }
        guard (editorImageData?.count ?? 0) <= maxImageBytes else {
            statusMessage = "Image exceeds the server upload limit (\(maxImageBytes) bytes). Replace it before saving."
            return false
        }
        guard !body.isEmpty || editorImageData != nil else {
            statusMessage = "Draft is empty"
            return false
        }

        let result = PerformanceSignposts.measure("DraftSave") {
            DraftPolicy.save(
                drafts: drafts,
                editingDraftID: editingDraftID,
                body: body,
                maxDrafts: maxDrafts,
                imageData: editorImageData,
                imageFilename: editorImageFilename,
                imageMimeType: editorImageMimeType
            )
        }
        if result.limitReached {
            statusMessage = isLapsed ? "You've reached 5 drafts without a plan." : hasPlanAccess ? "Draft limit reached. Delete a draft to create a new one." : "Draft limit reached. Delete a draft or upgrade to Pro."
            return false
        }
        if let editingDraftID, result.changedDraft != nil,
           let draft = drafts.first(where: { $0.id == editingDraftID }), !canEdit(draft) {
            statusMessage = Self.lapsedFrozenMessage
            return false
        }
        drafts = result.drafts
        editingDraftID = result.editingDraftID
        guard result.changedDraft != nil else {
            statusMessage = "Draft saved"
            return true
        }
        persistDrafts(ownerID: ownerID)
        localRevision += 1
        if let editingDraftID,
           let draft = drafts.first(where: { $0.id == editingDraftID }) {
            enqueueSync(.upsert, draftID: draft.id, draft: draft)
        }
        telemetry(.draftSaved, [:])
        statusMessage = isLapsed ? "Saved. \(Self.lapsedFrozenMessage)" : "Draft saved"
        return true
    }

    func syncCurrentDraftForScheduling() async throws -> Draft {
        guard !accountWorkSuspended else { throw LinkedInPostError.missingAuth }
        guard schedulingUploadTask == nil else { throw SyncedDraftsError.server("A scheduling upload is already in progress.") }
        guard saveCurrentDraft() else { throw SyncedDraftsError.server(statusMessage ?? "Draft could not be saved.") }
        guard let ownerID, let accessToken, let syncService,
              let editingDraftID, let draft = drafts.first(where: { $0.id == editingDraftID }) else {
            throw SyncedDraftsError.server("Save and sync this draft before scheduling.")
        }
        let revision = localRevision
        let generation = syncGeneration
        let editor = editorSnapshot
        statusMessage = isDraftSyncEnabled ? "Uploading draft for scheduling…" : "Scheduling requires uploading this draft even with sync off."
        let upload = Task { try await syncService.upsertDraft(draft, memberID: ownerID, accessToken: accessToken) }
        schedulingUploadTask = upload
        defer { schedulingUploadTask = nil }
        let synced = try await upload.value
        guard self.ownerID == ownerID, self.accessToken == accessToken,
              localRevision == revision, syncGeneration == generation, editorSnapshot == editor,
              let index = drafts.firstIndex(where: { $0.id == draft.id && $0 == draft }) else {
            throw SyncedDraftsError.server("Draft or account changed. Schedule the current draft again.")
        }
        drafts[index] = synced
        syncedIDs.insert(synced.id)
        persistDrafts(ownerID: ownerID)
        return synced
    }

    func syncDraftForScheduling(_ draft: Draft) async throws -> Draft {
        if editingDraftID == draft.id { return try await syncCurrentDraftForScheduling() }
        guard schedulingUploadTask == nil else { throw SyncedDraftsError.server("A scheduling upload is already in progress.") }
        guard !accountWorkSuspended, let ownerID, let accessToken, let syncService,
              let saved = drafts.first(where: { $0.id == draft.id }) else { throw LinkedInPostError.missingAuth }
        let generation = syncGeneration
        let upload = Task { try await syncService.upsertDraft(saved, memberID: ownerID, accessToken: accessToken) }
        schedulingUploadTask = upload
        defer { schedulingUploadTask = nil }
        let synced = try await upload.value
        guard self.ownerID == ownerID, self.accessToken == accessToken, syncGeneration == generation,
              let index = drafts.firstIndex(where: { $0 == saved }) else {
            throw SyncedDraftsError.server("Draft or account changed. Schedule again.")
        }
        drafts[index] = synced
        syncedIDs.insert(synced.id)
        persistDrafts(ownerID: ownerID)
        return synced
    }

    func saveOpenedDraftAndClearEditor() {
        if editingDraftID != nil, !saveCurrentDraft() { return }
        editorText = ""
        editorImageData = nil
        editorImageFilename = nil
        editorImageMimeType = nil
        editingDraftID = nil
        statusMessage = nil
    }

    @discardableResult
    func openDraft(_ draft: Draft) -> Bool {
        if editingDraftID == draft.id { return true }
        guard !hasUnsavedChanges else {
            pendingDraft = draft
            return false
        }
        applyDraft(draft)
        return true
    }

    func confirmOpenDraft() {
        guard let pendingDraft else { return }
        applyDraft(pendingDraft)
        self.pendingDraft = nil
    }

    private func applyDraft(_ draft: Draft) {
        editorText = draft.body
        editorImageData = draft.imageData
        editorImageFilename = draft.imageFilename
        editorImageMimeType = draft.imageMimeType
        editingDraftID = draft.id
        statusMessage = draft.remoteImage != nil && draft.imageData == nil ? "Image unavailable. Refresh to retry downloading it." : nil
    }

    func deleteDraft(_ draft: Draft) {
        guard canEdit(draft) else {
            statusMessage = Self.lapsedFrozenMessage
            return
        }
        drafts = DraftPolicy.delete(drafts, id: draft.id)
        if editingDraftID == draft.id {
            editingDraftID = nil
            editorImageData = nil
            editorImageFilename = nil
            editorImageMimeType = nil
        }
        persistDrafts(ownerID: ownerID)
        localRevision += 1
        syncDelete(id: draft.id, draft: draft)
    }

    func completePublishedDraft(_ snapshot: EditorSnapshot, savedDraft: Draft?) {
        guard ownerID == snapshot.ownerID else { return }
        let stillEditingSubmission = editorSnapshot == snapshot
        if let savedDraft, drafts.contains(savedDraft) {
            drafts = DraftPolicy.delete(drafts, id: savedDraft.id)
            persistDrafts(ownerID: ownerID)
            localRevision += 1
            syncDelete(id: savedDraft.id, draft: savedDraft)
            if editingDraftID == savedDraft.id { editingDraftID = nil }
        }
        if stillEditingSubmission { startNewPost() }
    }

    func deletePostedDraftIfSaved() {
        guard let editingDraftID else { return }
        self.editingDraftID = nil
        let postedDraft = drafts.first { $0.id == editingDraftID }
        let remaining = DraftPolicy.delete(drafts, id: editingDraftID)
        if remaining.count != drafts.count {
            drafts = remaining
            persistDrafts(ownerID: ownerID)
            localRevision += 1
            syncDelete(id: editingDraftID, draft: postedDraft)
        }
    }

    func suspendAccountWork() async {
        accountWorkSuspended = true
        syncGeneration += 1
        stopPeriodicSync()
        fetchTask?.cancel()
        drainTask?.cancel()
        schedulingUploadTask?.cancel()
        await fetchTask?.value
        await drainTask?.value
        _ = try? await schedulingUploadTask?.value
    }

    func resumeAccountWork() {
        accountWorkSuspended = false
        updatePeriodicSync()
        drainSyncQueue(thenFetchRemote: true)
    }

    func deleteAccountData(ownerID: String?) {
        accountWorkSuspended = true
        syncGeneration += 1
        accessToken = nil
        stopPeriodicSync()
        if let ownerID {
            draftRepository.deleteDrafts(ownerID: ownerID)
            draftRepository.deleteSyncMutations(ownerID: ownerID)
        }
        draftRepository.deleteDrafts(ownerID: nil)
        editorsByOwner.removeAll()
        syncSettingsStore.isDataReductionEnabled = false
        syncSettingsStore.save()
        setEntitlement(isPro: false, postCount: 0)
        scheduledPosts = []
        self.ownerID = nil
        drafts = []
        syncStatus = .localOnly
        localRevision += 1
        startNewPost()
    }

    func setEntitlement(isPro: Bool, postCount: Int, tier: EntitlementTier? = nil, subscriptionSource: String? = nil, accessUntil: Date? = nil, maxDraftBodyRunes: Int? = nil, maxImageBytes: Int? = nil) {
        self.tier = tier
        self.maxDraftBodyRunes = maxDraftBodyRunes ?? 4000
        self.maxImageBytes = maxImageBytes ?? 5 * 1024 * 1024
        self.accessUntil = accessUntil
        self.subscriptionSource = subscriptionSource
        self.isPro = isPro
        self.postCount = postCount
    }

    static let lapsedFrozenMessage = "Without a plan, drafts can't be edited, deleted, or published."

    /// `lapsed` drafts are read-only; a new one can still be saved while under the limit.
    func canEdit(_ draft: Draft) -> Bool {
        !isLapsed
    }

    /// Fetches remote drafts and merges them with local drafts. Throttled to
    /// avoid hammering the server when the app becomes active or the drafts
    /// view is opened repeatedly.
    func refreshFromRemote() {
        guard isDraftSyncEnabled, Date().timeIntervalSince(lastRemoteSyncAt) >= 2 else { return }
        lastRemoteSyncAt = Date()
        drainSyncQueue(thenFetchRemote: true)
    }

    func retrySync() {
        rearmParkedSyncMutations()
        drainSyncQueue(thenFetchRemote: true)
    }

    private func startPeriodicSync() {
        guard periodicSyncTimer == nil else { return }
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFromRemote() }
        }
    }

    private func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }

    private func updatePeriodicSync() {
        if ownerID != nil && accessToken != nil {
            startPeriodicSync()
        } else {
            stopPeriodicSync()
        }
    }

    private func persistDrafts(ownerID: String?) {
        PerformanceSignposts.measure("DraftPersist") {
            draftRepository.saveSnapshot(
                DraftSnapshot(drafts: drafts, ownerID: ownerID, lastSuccessfulSyncAt: lastSuccessfulSyncAt, syncedIDs: syncedIDs),
                ownerID: ownerID
            )
        }
    }

    private func syncFromRemote() {
        guard fetchTask == nil, isDraftSyncEnabled, let syncService, let accessToken, let ownerID else { return }
        let queue = draftRepository.loadSyncMutations(ownerID: ownerID)
        guard DraftSyncPolicy.dueMutations(from: queue).isEmpty else { return }
        let localDrafts = drafts
        let startedRevision = localRevision
        let generation = syncGeneration
        fetchTask = Task {
            defer { fetchTask = nil }
            let remoteDrafts: [Draft]
            do { remoteDrafts = try await syncService.listDrafts(memberID: ownerID, accessToken: accessToken) }
            catch {
                guard self.ownerID == ownerID, self.accessToken == accessToken, self.syncGeneration == generation else { return }
                logger.error("POST /api/drafts/sync refresh failed: \(String(describing: type(of: error)), privacy: .public)")
                syncStatus = .failed
                statusMessage = "Draft refresh failed. Showing the last saved data."
                return
            }
            let merged = await MainActor.run {
                guard self.ownerID == ownerID, self.accessToken == accessToken, self.localRevision == startedRevision, self.isDraftSyncEnabled, self.syncGeneration == generation else { return [Draft]() }
                let remoteIDs = Set(remoteDrafts.map(\.id))
                let pendingIDs = Set(queue.map(\.draftID))
                let deletedIDs = Set(queue.filter { $0.operation == .delete }.map(\.draftID))
                let retained = localDrafts.filter { !syncedIDs.contains($0.id) || remoteIDs.contains($0.id) || pendingIDs.contains($0.id) }
                let merged = DraftSyncPolicy.merge(local: retained, remote: remoteDrafts.filter { !deletedIDs.contains($0.id) }, maxDrafts: maxDrafts)
                syncedIDs.formUnion(remoteIDs)
                drafts = merged
                lastSuccessfulSyncAt = Date()
                persistDrafts(ownerID: ownerID)
                // Server draftIds differing only by case decode to one UUID; keep the newest.
                let remoteByID = Dictionary(remoteDrafts.map { ($0.id, $0) }) { $0.updatedAt >= $1.updatedAt ? $0 : $1 }
                return merged.filter { draft in
                    !pendingIDs.contains(draft.id) && (remoteByID[draft.id].map { draft.updatedAt > $0.updatedAt } ?? true)
                }
            }
            guard self.ownerID == ownerID, self.accessToken == accessToken,
                  self.localRevision == startedRevision, self.isDraftSyncEnabled,
                  self.syncGeneration == generation else { return }
            for draft in merged {
                enqueueSync(.upsert, draftID: draft.id, draft: draft)
            }
            drainSyncQueue()
        }
    }

    private func enqueueSync(_ operation: DraftSyncOperation, draftID: Draft.ID, draft: Draft? = nil) {
        guard let ownerID else {
            syncStatus = .localOnly
            return
        }
        let mutation = DraftSyncMutation(ownerID: ownerID, operation: operation, draftID: draftID, draft: draft)
        let queue = draftRepository.loadSyncMutations(ownerID: ownerID)
        let updatedQueue = DraftSyncPolicy.enqueue(mutation, into: queue)
        draftRepository.saveSyncMutations(updatedQueue, ownerID: ownerID)
        telemetry(.syncQueueLength, ["count": "\(updatedQueue.count)"])
        syncStatus = .pending
        drainSyncQueue()
    }

    private func syncDelete(id: Draft.ID, draft: Draft? = nil) {
        enqueueSync(.delete, draftID: id, draft: draft)
    }

    private func drainSyncQueue(thenFetchRemote: Bool = false) {
        guard !isDrainingSyncQueue else { return }
        guard isDraftSyncEnabled else {
            syncStatus = .disabled
            return
        }
        guard let syncService, let accessToken, let ownerID else {
            syncStatus = ownerID == nil ? .localOnly : .pending
            return
        }
        var queue = draftRepository.loadSyncMutations(ownerID: ownerID)
        if isLapsed {
            // The server rejects lapsed edits and deletes (402); only new drafts can still be pushed.
            let pushable = queue.filter { $0.operation == .upsert && !syncedIDs.contains($0.draftID) }
            if pushable.count != queue.count {
                queue = pushable
                draftRepository.saveSyncMutations(queue, ownerID: ownerID)
            }
        }
        guard !queue.isEmpty else {
            syncStatus = .synced
            if thenFetchRemote { syncFromRemote() }
            return
        }
        let due = DraftSyncPolicy.dueMutations(from: queue)
        guard !due.isEmpty else {
            syncStatus = queue.contains { $0.lastError != nil } ? .failed : .pending
            return
        }
        isDrainingSyncQueue = true
        let generation = syncGeneration
        drainTask = Task {
            for mutation in due {
                guard self.ownerID == ownerID, self.accessToken == accessToken, self.isDraftSyncEnabled, self.syncGeneration == generation else { break }
                guard draftRepository.loadSyncMutations(ownerID: ownerID).contains(where: { $0.id == mutation.id }) else { continue }
                do {
                    switch mutation.operation {
                    case .upsert:
                        guard let draft = mutation.draft else { continue }
                        let remoteDraft = try await syncService.upsertDraft(draft, memberID: ownerID, accessToken: accessToken)
                        guard self.ownerID == ownerID, self.accessToken == accessToken, self.isDraftSyncEnabled, self.syncGeneration == generation else { break }
                        queue = draftRepository.loadSyncMutations(ownerID: ownerID)
                        if queue.contains(where: { $0.id == mutation.id }),
                           drafts.contains(where: { $0.id == draft.id && $0 == draft }) {
                            syncedIDs.insert(remoteDraft.id)
                            drafts = DraftSyncPolicy.merge(local: drafts, remote: [remoteDraft], maxDrafts: maxDrafts)
                            persistDrafts(ownerID: ownerID)
                        }
                        queue.removeAll { $0.id == mutation.id }
                        draftRepository.saveSyncMutations(queue, ownerID: ownerID)
                    case .delete:
                        if let draft = mutation.draft {
                            try await syncService.deleteDraft(draft, memberID: ownerID, accessToken: accessToken)
                        } else {
                            try await syncService.deleteDraft(id: mutation.draftID, memberID: ownerID, accessToken: accessToken)
                        }
                        guard self.ownerID == ownerID, self.accessToken == accessToken, self.isDraftSyncEnabled, self.syncGeneration == generation else { break }
                        queue = draftRepository.loadSyncMutations(ownerID: ownerID)
                        queue.removeAll { $0.id == mutation.id }
                        draftRepository.saveSyncMutations(queue, ownerID: ownerID)
                    }
                    telemetry(.syncAttemptSucceeded, ["operation": mutation.operation.rawValue])
                } catch {
                    guard self.ownerID == ownerID, self.accessToken == accessToken, self.isDraftSyncEnabled, self.syncGeneration == generation else { break }
                    queue = draftRepository.loadSyncMutations(ownerID: ownerID)
                    if let index = queue.firstIndex(where: { $0.id == mutation.id }) {
                        queue[index] = DraftSyncPolicy.markFailed(mutation, error: error)
                        draftRepository.saveSyncMutations(queue, ownerID: ownerID)
                        telemetry(.syncAttemptFailed, ["operation": mutation.operation.rawValue])
                        logger.error("Sync \(mutation.operation.rawValue) failed for draft \(mutation.draftID): \(String(describing: type(of: error)), privacy: .public)")
                    }
                }
            }
            guard self.ownerID == ownerID, self.accessToken == accessToken, self.isDraftSyncEnabled, self.syncGeneration == generation else {
                isDrainingSyncQueue = false
                if isDraftSyncEnabled { drainSyncQueue(thenFetchRemote: true) }
                return
            }
            queue = draftRepository.loadSyncMutations(ownerID: ownerID)
            telemetry(.syncQueueLength, ["count": "\(queue.count)"])
            if queue.isEmpty {
                lastSuccessfulSyncAt = Date()
                persistDrafts(ownerID: ownerID)
            }
            syncStatus = queue.isEmpty ? .synced : (queue.contains { $0.lastError != nil } ? .failed : .pending)
            isDrainingSyncQueue = false
            if queue.isEmpty, thenFetchRemote {
                syncFromRemote()
            } else if !DraftSyncPolicy.dueMutations(from: queue).isEmpty {
                drainSyncQueue()
            }
        }
    }
}
