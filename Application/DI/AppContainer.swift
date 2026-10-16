import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer(configuration: .load())

    let draftStore: DraftStore
    let linkedInSessionStore: LinkedInSessionStore
    let authService: LinkedInAuthService
    let postService: LinkedInPostService
    let naturalizeService: NaturalizeService
    let entitlementService: EntitlementService
    let purchaseService: StoreKitPurchaseService
    let purchaseCoordinator: PurchaseCoordinator
    let feedbackService: FeedbackService
    let notificationTokenService: NotificationTokenService
    let draftRepository: DraftRepository
    let tokenStore: LinkedInTokenStore
    let aiSettingsStore: AISettingsStore
    let syncSettingsStore: SyncSettingsStore
    let configuration: AppConfiguration
    let editorViewModel: EditorViewModel
    let draftsViewModel: DraftsViewModel
    let accountViewModel: AccountViewModel

    init(configuration: AppConfiguration) {
        let draftRepository = UserDefaultsDraftRepository(key: configuration.storage.draftsKey)
        let tokenStore = AuthTokenStore(key: configuration.storage.linkedInTokenKey)
        let linkedInSessionStore = LinkedInSessionStore(tokenStore: tokenStore)

        self.configuration = configuration
        self.draftRepository = draftRepository
        self.tokenStore = tokenStore
        let authorizationPresenter = SafariAuthorizationPresenter()
        self.authService = LinkedInAuthService(
            apiBaseURL: configuration.api.baseURL,
            callbackURLScheme: configuration.linkedIn.callbackURLScheme,
            tokenStore: tokenStore,
            presenter: authorizationPresenter
        )
        self.postService = LinkedInPostService(apiBaseURL: configuration.api.baseURL)
        self.naturalizeService = NaturalizeService()
        self.entitlementService = EntitlementService(apiBaseURL: configuration.api.baseURL)
        self.purchaseService = StoreKitPurchaseService(apiBaseURL: configuration.api.baseURL)
        self.purchaseCoordinator = PurchaseCoordinator(
            purchaseService: self.purchaseService,
            entitlementService: self.entitlementService
        )
        self.feedbackService = FeedbackService(apiBaseURL: configuration.api.baseURL)
        self.notificationTokenService = NotificationTokenService(apiBaseURL: configuration.api.baseURL)
        self.linkedInSessionStore = linkedInSessionStore
        self.aiSettingsStore = AISettingsStore(keyStore: KeychainAIAPIKeyStore(service: "com.dailymind.bloomary.ai." + (configuration.api.baseURL.host ?? "unknown")))
        self.syncSettingsStore = SyncSettingsStore(key: configuration.storage.draftsKey + ".reduce-data")
        self.draftStore = DraftStore(
            draftRepository: draftRepository,
            syncService: SyncedDraftsService(apiBaseURL: configuration.api.baseURL),
            syncSettingsStore: syncSettingsStore,
            telemetry: AppTelemetry.track
        )
        self.draftsViewModel = DraftsViewModel(
            store: draftStore,
            postService: self.postService,
            sessionStore: linkedInSessionStore,
            scheduleMaxAheadDays: configuration.scheduling.maxAheadDays
        )
        self.editorViewModel = EditorViewModel(
            store: draftStore,
            sessionStore: linkedInSessionStore,
            authService: authService,
            postService: postService,
            naturalizeService: naturalizeService,
            storageNamespace: configuration.api.baseURL.host ?? "unknown",
            aiSettingsStore: aiSettingsStore,
            scheduleMaxAheadDays: configuration.scheduling.maxAheadDays
        )
        self.accountViewModel = AccountViewModel(
            authService: authService,
            sessionStore: linkedInSessionStore,
            draftStore: draftStore,
            aiSettingsStore: aiSettingsStore,
            legacyDraftRepository: UserDefaultsDraftRepository(key: "bloomary_drafts"),
            clearAccountCaches: { [entitlementService] memberID in
                entitlementService.clearCache(memberID: memberID)
                UserDefaults.standard.removeObject(forKey: "bloomary.publish-attempt.\(configuration.api.baseURL.host ?? "unknown").\(memberID)")
            },
            exportDraftArchive: DraftExportService(apiBaseURL: configuration.api.baseURL).export
        )
    }
}
