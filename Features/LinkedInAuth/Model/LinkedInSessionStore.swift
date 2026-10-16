import Foundation

@MainActor
final class LinkedInSessionStore: ObservableObject {
    @Published private(set) var token: LinkedInToken?
    @Published var statusMessage: String?

    private var expiryTask: Task<Void, Never>?
    private let tokenStore: LinkedInTokenStore

    init(tokenStore: LinkedInTokenStore) {
        self.tokenStore = tokenStore
        let storedToken = tokenStore.load()
        if storedToken?.isExpired == true {
            tokenStore.clear()
            self.token = nil
        } else {
            self.token = storedToken
        }
        scheduleExpiry()
    }

    deinit { expiryTask?.cancel() }

    var isConnected: Bool {
        token?.accessToken.isEmpty == false && token?.profile.memberID.isEmpty == false && token?.isExpired == false
    }

    var postCredential: LinkedInPostCredential? {
        guard let token, !token.isExpired else { return nil }
        return LinkedInPostCredential(accessToken: token.accessToken, memberID: token.profile.memberID)
    }

    func setToken(_ token: LinkedInToken) {
        guard tokenStore.save(token) else {
            self.token = nil
            statusMessage = "LinkedIn token could not be saved."
            return
        }
        self.token = token
        scheduleExpiry()
        statusMessage = nil
    }

    func expireIfNeeded() {
        guard token?.isExpired == true else { return }
        disconnect()
        statusMessage = "LinkedIn authorization expired. Reconnect to resume syncing."
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let token, let seconds = token.expiresIn, seconds > 0 else { return }
        let delay = max(0, token.connectedAt.addingTimeInterval(TimeInterval(seconds - 300)).timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard self?.token == token else { return }
            self?.expireIfNeeded()
        }
    }

    static let demoMemberID = "apple-review-demo"

    var isDemo: Bool {
        token?.profile.memberID == Self.demoMemberID
    }

    func setDemoSession(code: String) {
        let demoToken = LinkedInToken(
            accessToken: "apple-review:\(code)",
            tokenType: nil,
            scope: nil,
            expiresIn: 28800,
            profile: LinkedInProfile(
                memberID: Self.demoMemberID,
                name: "App Review",
                pictureURL: nil,
                email: nil,
                headline: nil,
                localizedHeadline: nil
            ),
            connectedAt: Date()
        )
        setToken(demoToken)
    }

    func disconnect() {
        expiryTask?.cancel()
        token = nil
        tokenStore.clear()
    }

    func deleteAccountData() {
        expiryTask?.cancel()
        token = nil
        tokenStore.clearAccountDeletionData()
    }
}
