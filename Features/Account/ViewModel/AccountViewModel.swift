import Combine
import Foundation
import OSLog

@MainActor
final class AccountViewModel: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoggingOut = false
    @Published private(set) var isDeletingAccount = false
    @Published private(set) var isExportingDrafts = false
    @Published private(set) var exportedDraftsURL: URL?

    private let legacyDraftRepository: DraftRepository?
    private let authService: AccountAuthServicing
    private let sessionStore: LinkedInSessionStore
    private let draftStore: DraftStore
    private let aiSettingsStore: AISettingsStore
    private let clearAccountCaches: (String) -> Void
    private let clearLegacyPostingCache: (String) -> Void
    private let exportDraftArchive: ((String, String) async throws -> URL)?
    private var cancellables = Set<AnyCancellable>()

    init(
        authService: AccountAuthServicing,
        sessionStore: LinkedInSessionStore,
        draftStore: DraftStore,
        aiSettingsStore: AISettingsStore,
        legacyDraftRepository: DraftRepository? = nil,
        clearAccountCaches: @escaping (String) -> Void = { memberID in
            UserDefaults.standard.removeObject(forKey: "bloomary_entitlement_\(memberID)")
        },
        clearLegacyPostingCache: @escaping (String) -> Void = { memberID in
            UserDefaults.standard.removeObject(forKey: "bloomary_streak_\(memberID)")
        },
        exportDraftArchive: ((String, String) async throws -> URL)? = nil
    ) {
        self.legacyDraftRepository = legacyDraftRepository
        self.authService = authService
        self.sessionStore = sessionStore
        self.draftStore = draftStore
        self.aiSettingsStore = aiSettingsStore
        self.clearAccountCaches = clearAccountCaches
        self.clearLegacyPostingCache = clearLegacyPostingCache
        self.exportDraftArchive = exportDraftArchive
        draftStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        sessionStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var recoverableDrafts: [Draft] {
        guard let repo = legacyDraftRepository else { return [] }
        let memberID = sessionStore.token?.profile.memberID
        let legacy = repo.loadDrafts(ownerID: memberID) + (memberID == nil ? [] : repo.loadDrafts(ownerID: nil))
        let existing = Set(draftStore.drafts.map(\.id))
        var seen = existing
        return legacy.filter { seen.insert($0.id).inserted }
    }
    var hasOlderDeviceDrafts: Bool { !recoverableDrafts.isEmpty }
    func recoverOlderDeviceDrafts() { draftStore.importLegacyDrafts(recoverableDrafts) }

    var planStatus: String {
        if draftStore.isPro {
            let source = draftStore.subscriptionSource == "apple" ? "App Store" : "Web"
            return "Pro · " + source
        }
        if draftStore.subscriptionSource == "trial", let end = draftStore.accessUntil, end > Date() {
            let days = max(1, Int(ceil(end.timeIntervalSinceNow / 86400)))
            return "Free trial · \(days) days left · ends \(end.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Free plan"
    }

    var subscriptionSource: String? { draftStore.subscriptionSource }

    var isConnected: Bool {
        sessionStore.isConnected
    }

    var isTokenExpired: Bool {
        sessionStore.token?.isExpired == true
    }

    var profile: LinkedInProfile? {
        sessionStore.token?.profile
    }

    var connectedAt: Date? {
        sessionStore.token?.connectedAt
    }

    private var expiresIn: Int? {
        sessionStore.token?.expiresIn
    }

    var tokenExpiresAt: Date? {
        guard let expiresIn, expiresIn > 0 else { return nil }
        return sessionStore.token?.connectedAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    var statusMessage: String? {
        sessionStore.statusMessage
    }

    func connect() {
        guard !isConnecting else { return }
        AppTelemetry.track(.linkedInConnectStarted)
        isConnecting = true
        Task {
            do {
                let token = try await authService.signIn()
                sessionStore.setToken(token)
                isConnecting = false
                AppTelemetry.track(.linkedInConnected)
            } catch {
                sessionStore.statusMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }

    func setDemoSession(code: String) {
        sessionStore.setDemoSession(code: code)
    }

    func logOut() {
        let token = sessionStore.token
        isLoggingOut = true
        Task {
            var remoteDisconnectFailed = false
            if let memberID = token?.profile.memberID, let accessToken = token?.accessToken {
                do {
                    try await authService.disconnect(memberID: memberID, accessToken: accessToken)
                } catch {
                    remoteDisconnectFailed = true
                    Logger(subsystem: "com.dailymind.bloomary", category: "Account").error("POST /api/linkedin/disconnect failed: \(String(describing: type(of: error)), privacy: .public)")
                }
                clearLegacyPostingCache(memberID)
            }
            guard sessionStore.token == token else { isLoggingOut = false; return }
            sessionStore.disconnect()
            sessionStore.statusMessage = remoteDisconnectFailed ? "Logged out locally." : "Logged out."
            isLoggingOut = false
        }
    }

    // Every access state may export, lapsed included.
    func exportDrafts() {
        guard !isExportingDrafts, let exportDraftArchive,
              let memberID = sessionStore.token?.profile.memberID, let accessToken = sessionStore.token?.accessToken else { return }
        isExportingDrafts = true
        Task {
            defer { isExportingDrafts = false }
            do {
                exportedDraftsURL = try await exportDraftArchive(memberID, accessToken)
            } catch {
                sessionStore.statusMessage = error.localizedDescription
            }
        }
    }

    func deleteAccount(onSuccess: @escaping () -> Void = {}) {
        guard !isDeletingAccount else { return }
        let token = sessionStore.token
        let memberID = token?.profile.memberID
        isDeletingAccount = true
        Task {
            defer { isDeletingAccount = false }
            await draftStore.suspendAccountWork()
            guard sessionStore.token == token else { return }
            do {
                if let memberID = token?.profile.memberID, let accessToken = token?.accessToken {
                    try await authService.deleteAccount(memberID: memberID, accessToken: accessToken)
                }
                guard sessionStore.token == token else { return }
                draftStore.deleteAccountData(ownerID: memberID)
                let clearedAIKey = aiSettingsStore.clearAccountDeletionData()
                if let memberID {
                    clearLegacyPostingCache(memberID)
                    clearAccountCaches(memberID)
                    UserDefaults.standard.removeObject(forKey: "bloomary.publish-attempt.\(memberID)")
                }
                for key in ["bloomary.active-schedule-id", "bloomary.active-schedule-status", "bloomary.schedule-ids", "bloomary.schedule-statuses"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                sessionStore.deleteAccountData()
                authService.requireFreshSignInOnce()
                sessionStore.statusMessage = clearedAIKey ? "Account deleted." : "Account deleted. The device Gemini key could not be cleared; unlock the device and use Clear Gemini key."
                isDeletingAccount = false
                AppTelemetry.track(.accountDeleted)
                onSuccess()
            } catch {
                guard sessionStore.token == token else { return }
                draftStore.resumeAccountWork()
                sessionStore.statusMessage = error.localizedDescription
                isDeletingAccount = false
            }
        }
    }
}
