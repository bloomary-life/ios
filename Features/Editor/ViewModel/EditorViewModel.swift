import Combine
import CryptoKit
import Foundation
import UIKit
import OSLog

@MainActor
final class EditorViewModel: ObservableObject {
    @Published private(set) var isPosting = false
    @Published private(set) var isNaturalizing = false
    @Published var editorText = "" {
        didSet {
            guard editorText != store.editorText else { return }
            store.editorText = editorText
        }
    }
    @Published var showsPublishRetryConfirmation = false
    @Published var showsPostSuccess = false
    @Published var showsSchedulePicker = false
    @Published var isScheduling = false
    @Published var scheduleMessage: String?
    @Published var showsSchedulePublishedAlert = false
    @Published var showsScheduleFailureAlert = false
    @Published var scheduleFailureMessage: String?
    @Published private(set) var scheduleStatus: String?
    @Published private(set) var scheduledAt: Date?
    private var isRefreshingSchedules = false
    private var scheduleID: String?
    private var scheduleIDs: [String] = []
    private var scheduleStatuses: [String: String] = [:]

    private let store: DraftStore
    private let sessionStore: LinkedInSessionStore
    private let authService: LinkedInAuthService
    private let postService: LinkedInPostService
    private let naturalizeService: NaturalizeService
    private let aiSettingsStore: AISettingsStore
    private let storageNamespace: String
    private let scheduleMaxAheadDays: Int
    private var cancellables = Set<AnyCancellable>()

    init(
        store: DraftStore,
        sessionStore: LinkedInSessionStore,
        authService: LinkedInAuthService,
        postService: LinkedInPostService,
        naturalizeService: NaturalizeService,
        storageNamespace: String = "",
        aiSettingsStore: AISettingsStore,
        scheduleMaxAheadDays: Int = AppConfiguration.Scheduling.default.maxAheadDays
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.authService = authService
        self.postService = postService
        self.naturalizeService = naturalizeService
        self.storageNamespace = storageNamespace
        self.aiSettingsStore = aiSettingsStore
        self.scheduleMaxAheadDays = scheduleMaxAheadDays
        self.editorText = store.editorText
        sessionStore.$token.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleIDs = []
                self.scheduleStatuses = [:]
                self.resetVisibleSchedule()
            }
        }.store(in: &cancellables)
        store.$editingDraftID.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.resetVisibleSchedule() }
        }.store(in: &cancellables)
        store.$editorText
            .sink { [weak self] text in
                guard let self, self.editorText != text else { return }
                self.editorText = text
            }
            .store(in: &cancellables)
        store.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        sessionStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var statusMessage: String? {
        store.statusMessage
    }

    var syncStatus: DraftSyncStatus {
        store.syncStatus
    }

    var isPro: Bool {
        store.isPro
    }

    var isLapsed: Bool {
        store.isLapsed
    }

    /// `lapsed` cannot publish or schedule; posts scheduled before the lapse still fire server-side.
    func showPlanRequired() {
        store.statusMessage = AccessBannerCopy.publishNeedsPlan
    }

    var isDraftLimitReached: Bool {
        store.isDraftLimitReached
    }

    var isEditingExistingDraft: Bool {
        store.isEditingExistingDraft
    }

    var isNewDraftBlockedByLimit: Bool {
        store.isDraftLimitReached && !store.isEditingExistingDraft
    }

    var draftLimitWarning: String? {
        guard isNewDraftBlockedByLimit else { return nil }
        if store.isLapsed { return "You've reached 5 drafts without a plan." }
        let action = store.hasPlanAccess ? "Delete a draft to create a new one." : "Delete a draft or upgrade to Pro."
        return "You have \(store.drafts.count) drafts (\(store.hasPlanAccess ? "Pro" : "free") limit: \(store.maxDrafts)). \(action)"
    }

    var profile: LinkedInProfile? {
        sessionStore.token?.profile
    }

    var hasEditorText: Bool {
        !DraftPolicy.trimmedBody(editorText).isEmpty
    }

    var previewText: String {
        DraftPolicy.trimmedBody(editorText).isEmpty ? "Preview appears here." : editorText
    }

    var maximumScheduleDate: Date {
        Date().addingTimeInterval(TimeInterval(scheduleMaxAheadDays * 24 * 60 * 60))
    }

    var scheduleLimitText: String {
        "Schedule between 5 minutes and \(scheduleMaxAheadDays) days ahead."
    }

    var maxImageBytes: Int { store.maxImageBytes }

    var attachedImage: UIImage? {
        guard let data = store.editorImageData else { return nil }
        return UIImage(data: data)
    }

    @discardableResult
    func save() -> Bool {
        store.saveCurrentDraft()
    }

    func schedule(at date: Date) {
        guard !store.isLapsed else { return showPlanRequired() }
        guard !isScheduling, let credential = sessionStore.postCredential else { return }
        guard date >= Date().addingTimeInterval(AppConfiguration.Scheduling.minimumLeadTime), date <= maximumScheduleDate else {
            scheduleMessage = "Choose a time between 5 minutes and \(scheduleMaxAheadDays) days from now."
            return
        }
        isScheduling = true
        scheduleMessage = nil
        Task {
            defer { isScheduling = false }
            do {
                let draft = try await store.syncCurrentDraftForScheduling()
                guard sessionStore.postCredential == credential else { throw LinkedInPostError.missingAuth }
                let snapshot = store.editorSnapshot
                let result = try await postService.schedule(draftID: draft.id, wireID: draft.serverID, at: date, credential: credential)
                guard sessionStore.postCredential == credential, store.editorSnapshot == snapshot else { return }
                store.setScheduledPosts(store.scheduledPosts.filter { $0.scheduleId != result.scheduleId } + [result], credential: credential)
                scheduleID = result.scheduleId
                if !scheduleIDs.contains(result.scheduleId) { scheduleIDs.append(result.scheduleId) }
                scheduledAt = date
                scheduleStatus = result.status
                scheduleStatuses[result.scheduleId] = result.status
                scheduleMessage = "Scheduled for \(date.formatted(date: .abbreviated, time: .shortened))."
                showsSchedulePicker = false
                store.statusMessage = scheduleMessage
            } catch {
                if sessionStore.postCredential == credential { scheduleMessage = error.localizedDescription }
            }
        }
    }

    private func resetVisibleSchedule() {
        scheduleID = nil
        scheduleStatus = nil
        scheduledAt = nil
        scheduleMessage = nil
        scheduleFailureMessage = nil
        showsSchedulePublishedAlert = false
        showsScheduleFailureAlert = false
        showsSchedulePicker = false
    }

    func refreshScheduleStatus() async {
        guard !isRefreshingSchedules, let credential = sessionStore.postCredential else { return }
        isRefreshingSchedules = true
        defer { isRefreshingSchedules = false }
        let requestedAt = Date()
        do {
            var posts = try await postService.scheduledPosts(credential: credential)
            for id in scheduleIDs where !posts.contains(where: { $0.scheduleId == id }) {
                posts.append(try await postService.scheduleStatus(id: id, credential: credential))
            }
            guard sessionStore.postCredential == credential else { return }
            guard store.setScheduledPosts(posts, credential: credential, requestedAt: requestedAt) else { return }
            for post in posts {
                let previous = scheduleStatuses[post.scheduleId]
                if let previous, previous != post.status {
                    if post.status == "published" { showsSchedulePublishedAlert = true }
                    if ["failed", "needs_review"].contains(post.status) {
                        scheduleFailureMessage = post.message ?? "Scheduled post needs attention."
                        showsScheduleFailureAlert = true
                    }
                }
            }
            let active = posts.filter { ["pending", "processing", "retry", "needs_review"].contains($0.status) }
            scheduleIDs = active.map(\.scheduleId)
            scheduleStatuses = Dictionary(uniqueKeysWithValues: active.map { ($0.scheduleId, $0.status) })
            if let post = posts.first(where: { UUID(uuidString: $0.draftId ?? "") == store.editingDraftID }) {
                scheduleID = post.scheduleId
                scheduleStatus = post.status
                scheduledAt = ISO8601DateFormatter().date(from: post.scheduledAt)
                scheduleMessage = post.message ?? (post.status == "published" ? "Published on LinkedIn." : nil)
            } else {
                scheduleID = nil
                scheduleStatus = nil
                scheduledAt = nil
                scheduleMessage = nil
            }
        } catch {
            guard sessionStore.postCredential == credential else { return }
            Logger(subsystem: "com.dailymind.bloomary", category: "Schedules").error("Schedule reconciliation failed: \(String(describing: type(of: error)), privacy: .public)")
            scheduleMessage = "Schedule refresh failed. Showing the last known status."
        }
    }

    func clearEditor() {
        store.saveOpenedDraftAndClearEditor()
    }

    func setAttachedImage(_ attachment: LinkedInPostAttachment) {
        store.editorImageData = attachment.data
        store.editorImageFilename = attachment.filename
        store.editorImageMimeType = attachment.mimeType
        store.statusMessage = "Image attached."
    }

    func removeAttachedImage() {
        store.editorImageData = nil
        store.editorImageFilename = nil
        store.editorImageMimeType = nil
    }

    private func publishFingerprint(_ snapshot: DraftStore.EditorSnapshot) -> String {
        var data = Data(snapshot.text.utf8)
        data.append(0)
        data.append(snapshot.imageData ?? Data())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func publish(confirmRetry: Bool = false) {
        guard !store.isLapsed else { return showPlanRequired() }
        guard !isPosting else { return }
        let snapshot = store.editorSnapshot
        AppTelemetry.track(.postStarted)
        isPosting = true
        Task {
            let signpost = PerformanceSignposts.beginAsyncInterval("PublishAttempt")
            await performPublish(origin: snapshot, confirmRetry: confirmRetry)
            PerformanceSignposts.endAsyncInterval("PublishAttempt", signpost)
        }
    }

    func naturalizeEnglish() {
        guard !isNaturalizing else { return }
        isNaturalizing = true
        store.statusMessage = "Naturalizing English..."
        let snapshot = store.editorSnapshot
        let credential = sessionStore.postCredential
        Task {
            await performNaturalize(snapshot: snapshot, credential: credential)
        }
    }

    private func performNaturalize(snapshot: DraftStore.EditorSnapshot, credential: LinkedInPostCredential?) async {
        do {
            let text = try await naturalizeService.naturalize(text: snapshot.text, settings: aiSettingsStore.current)
            guard store.editorSnapshot == snapshot, sessionStore.postCredential == credential else {
                isNaturalizing = false
                return
            }
            editorText = text
            store.statusMessage = "Naturalized English."
        } catch {
            if store.editorSnapshot == snapshot, sessionStore.postCredential == credential {
                store.statusMessage = error.localizedDescription
            }
        }
        isNaturalizing = false
    }

    private func performPublish(origin: DraftStore.EditorSnapshot, confirmRetry: Bool) async {
        defer { isPosting = false }
        var publishingCredential: LinkedInPostCredential?
        do {
            try await connectIfNeeded()
            let submitted = store.editorSnapshot
            guard submitted.text == origin.text, submitted.imageData == origin.imageData,
                  submitted.draftID == origin.draftID,
                  origin.ownerID == nil || submitted.ownerID == origin.ownerID,
                  let credential = sessionStore.postCredential else {
                store.statusMessage = "Editor changed while connecting. Review your post and publish again."
                return
            }
            publishingCredential = credential
            let attemptKey = "bloomary.publish-attempt.\(storageNamespace).\(credential.memberID)"
            let fingerprint = publishFingerprint(submitted)
            if !confirmRetry, UserDefaults.standard.string(forKey: attemptKey) == fingerprint {
                showsPublishRetryConfirmation = true
                return
            }
            UserDefaults.standard.set(fingerprint, forKey: attemptKey)
            let savedDraft = store.drafts.first { $0.id == submitted.draftID }
            _ = try await postService.publish(
                text: editorText,
                credential: credential,
                attachment: postAttachment,
                draftID: savedDraft?.serverID
            )
            guard sessionStore.postCredential == credential else { return }
            store.completePublishedDraft(submitted, savedDraft: savedDraft)
            finishPost(message: "Posted to LinkedIn", event: .postSucceeded)
            showsPostSuccess = true
        } catch LinkedInPostError.authorizationExpired {
            guard sessionStore.postCredential == publishingCredential else { return }
            sessionStore.disconnect()
            finishPost(message: LinkedInPostError.authorizationExpired.localizedDescription, event: .postFailed)
        } catch {
            guard publishingCredential == nil || sessionStore.postCredential == publishingCredential else { return }
            finishPost(message: error.localizedDescription, event: .postFailed)
        }
    }

    private var postAttachment: LinkedInPostAttachment? {
        guard let data = store.editorImageData else { return nil }
        return LinkedInPostAttachment(
            data: data,
            filename: store.editorImageFilename ?? "bloomary-linkedin-image.jpg",
            mimeType: store.editorImageMimeType ?? "image/jpeg"
        )
    }

    private func connectIfNeeded() async throws {
        guard !sessionStore.isConnected else { return }
        AppTelemetry.track(.linkedInConnectStarted)
        let token = try await authService.signIn()
        sessionStore.setToken(token)
        AppTelemetry.track(.linkedInConnected)
    }

    private func finishPost(message: String, event: AppTelemetryEvent) {
        store.statusMessage = message
        isPosting = false
        AppTelemetry.track(event)
    }
}
