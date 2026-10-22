import Combine
import Foundation
import OSLog

@MainActor
final class DraftsViewModel: ObservableObject {
    private let store: DraftStore
    private let postService: LinkedInPostService?
    private let sessionStore: LinkedInSessionStore?
    private let scheduleMaxAheadDays: Int
    var scheduledPosts: [ScheduledPostResult] { store.scheduledPosts }
    private var cancellables = Set<AnyCancellable>()

    init(store: DraftStore, postService: LinkedInPostService? = nil, sessionStore: LinkedInSessionStore? = nil, scheduleMaxAheadDays: Int = AppConfiguration.Scheduling.default.maxAheadDays) {
        self.store = store
        self.postService = postService
        self.sessionStore = sessionStore
        self.scheduleMaxAheadDays = scheduleMaxAheadDays
        store.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var drafts: [Draft] {
        store.drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    var syncStatus: DraftSyncStatus {
        store.syncStatus
    }

    var statusMessage: String? {
        store.statusMessage
    }

    var isPro: Bool {
        store.isPro
    }

    var draftCountText: String {
        store.draftCountText
    }

    var isNearDraftLimit: Bool {
        !store.hasPlanAccess && store.drafts.count >= store.maxDrafts - 1
    }

    var isDraftLimitReached: Bool {
        store.isDraftLimitReached
    }

    var isOverDraftLimit: Bool {
        store.isDraftLimitReached && store.drafts.count > store.maxDrafts
    }

    var overLimitMessage: String {
        if store.isLapsed { return "You've reached 5 drafts without a plan." }
        let tier = store.hasPlanAccess ? "Pro" : "free"
        let action = store.hasPlanAccess ? "Delete a draft to create a new one." : "Delete some to create new ones or upgrade to Pro."
        return "You have \(store.drafts.count) drafts (\(tier) limit: \(store.maxDrafts)). \(action)"
    }

    var maximumScheduleDate: Date {
        Date().addingTimeInterval(TimeInterval(scheduleMaxAheadDays * 24 * 60 * 60))
    }

    func open(_ draft: Draft) -> Bool {
        store.openDraft(draft)
    }

    func delete(_ draft: Draft) {
        store.deleteDraft(draft)
    }

    func retrySync() { store.retrySync() }

    func refreshFromRemote() {
        store.refreshFromRemote()
        refreshSchedules()
    }

    func scheduledPost(for draft: Draft) -> ScheduledPostResult? {
        scheduledPosts.first { UUID(uuidString: $0.draftId ?? "") == draft.id }
    }

    func reschedule(_ draft: Draft, at date: Date, reviewConfirmed: Bool = false) async throws {
        guard let postService, let sessionStore, let credential = sessionStore.postCredential else { throw LinkedInPostError.missingAuth }
        guard date >= Date().addingTimeInterval(AppConfiguration.Scheduling.minimumLeadTime), date <= maximumScheduleDate else {
            throw SyncedDraftsError.server("Choose a time between five minutes and the scheduling limit.")
        }
        let synced = try await store.syncDraftForScheduling(draft)
        guard sessionStore.postCredential == credential else { throw LinkedInPostError.missingAuth }
        let result = try await postService.schedule(draftID: synced.id, wireID: synced.serverID, reviewConfirmed: reviewConfirmed, at: date, credential: credential)
        guard sessionStore.postCredential == credential else { return }
        store.setScheduledPosts(scheduledPosts.filter { UUID(uuidString: $0.draftId ?? "") != draft.id } + [result], credential: credential)
    }

    func unschedule(_ draft: Draft) async throws {
        guard let postService, let sessionStore, let credential = sessionStore.postCredential else { throw LinkedInPostError.missingAuth }
        try await postService.unschedule(draftID: draft.serverID, credential: credential)
        guard sessionStore.postCredential == credential else { return }
        store.setScheduledPosts(scheduledPosts.filter { UUID(uuidString: $0.draftId ?? "") != draft.id }, credential: credential)
    }

    private func refreshSchedules() {
        guard let postService, let sessionStore, let credential = sessionStore.postCredential else {
            return
        }
        let requestedAt = Date()
        Task {
            do {
                let posts = try await postService.scheduledPosts(credential: credential)
                guard sessionStore.postCredential == credential else { return }
                store.setScheduledPosts(posts, credential: credential, requestedAt: requestedAt)
            } catch {
                guard sessionStore.postCredential == credential else { return }
                Logger(subsystem: "com.dailymind.bloomary", category: "Schedules").error("GET /api/linkedin/schedules failed: \(String(describing: type(of: error)), privacy: .public)")
                store.statusMessage = "Schedule refresh failed. Showing the last known status."
            }
        }
    }

    func canEdit(_ draft: Draft) -> Bool {
        store.canEdit(draft)
    }
}
