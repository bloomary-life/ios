import Foundation
import Testing
@testable import Bloomary

@MainActor
struct ViewModelTests {
    @Test
    func draftsViewModelReflectsStoreAndDelegatesCommands() {
        let repository = ViewModelTestDraftRepository()
        let draft = Draft(body: "Draft body")
        repository.setDrafts([draft], ownerID: nil)
        let store = DraftStore(draftRepository: repository)
        let viewModel = DraftsViewModel(store: store)

        #expect(viewModel.drafts == [draft])

        viewModel.open(draft)
        #expect(store.editorText == "Draft body")

        viewModel.delete(draft)
        #expect(viewModel.drafts.isEmpty)
        #expect(repository.savedDrafts(ownerID: nil).isEmpty)
    }

    @Test
    func editorViewModelForwardsTextAndSaveCommand() {
        let repository = ViewModelTestDraftRepository()
        let store = DraftStore(draftRepository: repository)
        let viewModel = makeEditorViewModel(store: store)

        viewModel.editorText = "  Hello from editor  "
        #expect(store.editorText == "  Hello from editor  ")
        #expect(viewModel.hasEditorText)
        #expect(viewModel.previewText == "  Hello from editor  ")

        viewModel.save()

        #expect(viewModel.statusMessage == "Draft saved")
        #expect(store.drafts.map(\.body) == ["Hello from editor"])
        #expect(repository.savedDrafts(ownerID: nil).map(\.body) == ["Hello from editor"])
    }

    @Test
    func editorViewModelShowsPlaceholderPreviewForEmptyText() {
        let store = DraftStore(draftRepository: ViewModelTestDraftRepository())
        let viewModel = makeEditorViewModel(store: store)

        viewModel.editorText = "   "

        #expect(!viewModel.hasEditorText)
        #expect(viewModel.previewText == "Preview appears here.")
    }

    @Test
    func editorViewModelClearEditorSavesAndEmpties() {
        let repository = ViewModelTestDraftRepository()
        let draft = Draft(body: "Opened")
        repository.setDrafts([draft], ownerID: nil)
        let store = DraftStore(draftRepository: repository)
        let viewModel = makeEditorViewModel(store: store)

        #expect(store.openDraft(draft))
        viewModel.editorText = "Edited"
        viewModel.clearEditor()

        #expect(viewModel.editorText.isEmpty)
        #expect(store.drafts.first?.body == "Edited")
    }

    @Test
    func editorViewModelLapsedPublishAsksForPlan() {
        let store = DraftStore(draftRepository: ViewModelTestDraftRepository())
        store.setEntitlement(isPro: false, postCount: 0, tier: .lapsed, subscriptionSource: "trial")
        let viewModel = makeEditorViewModel(store: store)
        viewModel.editorText = "Post"

        viewModel.publish()
        viewModel.schedule(at: Date().addingTimeInterval(3600))

        #expect(viewModel.isLapsed)
        #expect(!viewModel.isPosting)
        #expect(!viewModel.isScheduling)
        #expect(viewModel.statusMessage == AccessBannerCopy.publishNeedsPlan)
    }

    @Test
    func accountViewModelLogOutClearsSession() async throws {
        let auth = FakeAccountAuthService()
        let sessionStore = makeSessionStore()
        let aiSettingsStore = makeAISettingsStore()
        aiSettingsStore.apiKey = "secret-key"
        sessionStore.setToken(makeToken(memberID: "member-1"))
        var clearedLegacyMemberIDs: [String] = []
        let viewModel = AccountViewModel(
            authService: auth,
            sessionStore: sessionStore,
            draftStore: DraftStore(draftRepository: ViewModelTestDraftRepository()),
            aiSettingsStore: aiSettingsStore,
            clearLegacyPostingCache: { clearedLegacyMemberIDs.append($0) }
        )

        viewModel.logOut()

        try await waitForCondition { sessionStore.statusMessage == "Logged out." }
        #expect(auth.disconnectedMemberIDs == ["member-1"])
        #expect(clearedLegacyMemberIDs == ["member-1"])
        #expect(!viewModel.isConnected)
        #expect(!viewModel.isLoggingOut)
        #expect(aiSettingsStore.apiKey == "secret-key")
    }

    @Test
    func accountViewModelDeleteAccountClearsLocalData() async throws {
        let auth = FakeAccountAuthService()
        let sessionStore = makeSessionStore()
        sessionStore.setToken(makeToken(memberID: "member-1"))
        let draftRepository = ViewModelTestDraftRepository()
        draftRepository.setDrafts([Draft(body: "Member draft")], ownerID: "member-1")
        let draftStore = DraftStore(draftRepository: draftRepository)
        draftStore.setOwnerID("member-1")
        let aiSettingsStore = makeAISettingsStore()
        aiSettingsStore.apiKey = "secret-key"
        var clearedLegacyMemberIDs: [String] = []
        let viewModel = AccountViewModel(
            authService: auth,
            sessionStore: sessionStore,
            draftStore: draftStore,
            aiSettingsStore: aiSettingsStore,
            clearLegacyPostingCache: { clearedLegacyMemberIDs.append($0) }
        )

        var didSucceed = false
        viewModel.deleteAccount { didSucceed = true }

        try await waitForCondition { didSucceed }
        #expect(auth.deletedMemberIDs == ["member-1"])
        #expect(auth.didRequireFreshSignIn)
        #expect(clearedLegacyMemberIDs == ["member-1"])
        #expect(!viewModel.isConnected)
        #expect(draftStore.drafts.isEmpty)
        #expect(draftRepository.savedDrafts(ownerID: "member-1").isEmpty)
        #expect(aiSettingsStore.apiKey.isEmpty)
        #expect(viewModel.statusMessage == "Account deleted.")
    }

    @Test
    func accountViewModelConnectFailureSurfacesMessage() async throws {
        let auth = FakeAccountAuthService(error: TestFailure.failed)
        let sessionStore = makeSessionStore()
        let viewModel = AccountViewModel(
            authService: auth,
            sessionStore: sessionStore,
            draftStore: DraftStore(draftRepository: ViewModelTestDraftRepository()),
            aiSettingsStore: makeAISettingsStore()
        )

        viewModel.connect()

        try await waitForCondition { sessionStore.statusMessage != nil }
        #expect(sessionStore.statusMessage == "failed")
        #expect(!viewModel.isConnecting)
        #expect(!viewModel.isConnected)
    }

    @Test
    func accountViewModelIgnoresDuplicateConnectWhileConnecting() async throws {
        let auth = FakeAccountAuthService(error: LinkedInAuthError.timedOut, delayNanoseconds: 50_000_000)
        let sessionStore = makeSessionStore()
        let viewModel = AccountViewModel(
            authService: auth,
            sessionStore: sessionStore,
            draftStore: DraftStore(draftRepository: ViewModelTestDraftRepository()),
            aiSettingsStore: makeAISettingsStore()
        )

        viewModel.connect()
        viewModel.connect()

        try await waitForCondition { sessionStore.statusMessage != nil }
        #expect(auth.signInCount == 1)
        #expect(sessionStore.statusMessage == "LinkedIn authorization timed out.")
        #expect(!viewModel.isConnecting)
        #expect(!viewModel.isConnected)
    }

    private func makeEditorViewModel(store: DraftStore) -> EditorViewModel {
        let baseURL = URL(string: "https://example.com")!
        return EditorViewModel(
            store: store,
            sessionStore: makeSessionStore(),
            authService: LinkedInAuthService(
                apiBaseURL: baseURL,
                callbackURLScheme: "test",
                tokenStore: ViewModelTestTokenStore(),
                presenter: NoOpAuthorizationPresenter()
            ),
            postService: LinkedInPostService(apiBaseURL: baseURL),
            naturalizeService: NaturalizeService(),
            aiSettingsStore: makeAISettingsStore()
        )
    }

    private func makeSessionStore() -> LinkedInSessionStore {
        LinkedInSessionStore(tokenStore: ViewModelTestTokenStore())
    }

    private func makeAISettingsStore() -> AISettingsStore {
        AISettingsStore(keyStore: ViewModelTestKeyStore())
    }

    private func makeToken(memberID: String) -> LinkedInToken {
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
}

private enum TestFailure: LocalizedError {
    case failed

    var errorDescription: String? { "failed" }
}

private final class FakeAccountAuthService: AccountAuthServicing {
    private(set) var disconnectedMemberIDs: [String] = []
    private(set) var deletedMemberIDs: [String] = []
    private(set) var didRequireFreshSignIn = false
    private(set) var signInCount = 0
    private let error: Error?
    private let delayNanoseconds: UInt64

    init(error: Error? = nil, delayNanoseconds: UInt64 = 0) {
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func signIn() async throws -> LinkedInToken {
        signInCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
        throw TestFailure.failed
    }

    func disconnect(memberID: String, accessToken: String) async throws {
        if let error { throw error }
        disconnectedMemberIDs.append(memberID)
    }

    func deleteAccount(memberID: String, accessToken: String) async throws {
        if let error { throw error }
        deletedMemberIDs.append(memberID)
    }

    func requireFreshSignInOnce() {
        didRequireFreshSignIn = true
    }
}

private final class ViewModelTestTokenStore: LinkedInTokenStore {
    private var token: LinkedInToken?

    func load() -> LinkedInToken? { token }
    func save(_ token: LinkedInToken) -> Bool {
        self.token = token
        return true
    }
    func clear() { token = nil }
}

private final class ViewModelTestKeyStore: AIAPIKeyStore {
    func load() -> String? { nil }
    func save(_ apiKey: String) -> Bool { true }
    func clear() -> Bool { true }
}

private final class ViewModelTestDraftRepository: DraftRepository {
    private var draftsByOwnerID: [String: [Draft]] = [:]

    func loadDrafts(ownerID: String?) -> [Draft] {
        draftsByOwnerID[ownerID ?? "signed-out"] ?? []
    }

    func saveDrafts(_ drafts: [Draft], ownerID: String?) {
        draftsByOwnerID[ownerID ?? "signed-out"] = drafts
    }

    func deleteDrafts(ownerID: String?) {
        draftsByOwnerID.removeValue(forKey: ownerID ?? "signed-out")
    }

    func setDrafts(_ drafts: [Draft], ownerID: String?) {
        draftsByOwnerID[ownerID ?? "signed-out"] = drafts
    }

    func savedDrafts(ownerID: String?) -> [Draft] {
        draftsByOwnerID[ownerID ?? "signed-out"] ?? []
    }
}

private func waitForCondition(
    timeout: Duration = .seconds(1),
    condition: @escaping () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !Task.isCancelled {
        if condition() { return }
        if start.duration(to: ContinuousClock.now) > timeout { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private struct NoOpAuthorizationPresenter: AuthorizationPresenter {
    func present(url: URL) async throws {}
    func complete(with url: URL) {}
    func cancel() {}
}
