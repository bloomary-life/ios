import Foundation
import Combine
import Testing
@testable import Bloomary

@MainActor
struct LinkedInSessionStoreTests {
    @Test
    func foregroundExpiryClearsSessionAndReconnectRestoresUnsavedEditor() async throws {
        let tokenStore = InMemoryTokenStore()
        let session = LinkedInSessionStore(tokenStore: tokenStore)
        let name = "LinkedInSessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let drafts = DraftStore(draftRepository: UserDefaultsDraftRepository(key: "drafts", defaults: defaults))
        let subscription = session.$token.sink { drafts.setSession($0) }
        defer { subscription.cancel() }
        session.setToken(Self.token(memberID: "member-1", expiresIn: 301, connectedAt: Date().addingTimeInterval(-0.8)))
        drafts.editorText = "Unsaved work"

        for _ in 0..<100 {
            if session.token == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(session.token == nil)
        #expect(session.postCredential == nil)
        #expect(tokenStore.savedToken == nil)
        #expect(session.statusMessage?.contains("Reconnect") == true)
        session.setToken(Self.token(memberID: "member-1"))
        #expect(session.isConnected)
        #expect(drafts.editorText == "Unsaved work")
    }

    @Test
    func connectionStateRequiresTokenAndMemberID() {
        let tokenStore = InMemoryTokenStore()
        let store = LinkedInSessionStore(tokenStore: tokenStore)

        #expect(!store.isConnected)

        store.setToken(Self.token(memberID: "member-1"))

        #expect(store.isConnected)
        #expect(tokenStore.savedToken?.profile.memberID == "member-1")
    }

    @Test
    func disconnectClearsToken() {
        let tokenStore = InMemoryTokenStore()
        let store = LinkedInSessionStore(tokenStore: tokenStore)
        store.setToken(Self.token(memberID: "member-1"))

        store.disconnect()

        #expect(!store.isConnected)
        #expect(tokenStore.savedToken == nil)
    }

    @Test
    func expiredTokenIsNotConnected() {
        let tokenStore = InMemoryTokenStore()
        tokenStore.savedToken = Self.token(memberID: "member-1", expiresIn: 1, connectedAt: Date(timeIntervalSince1970: 0))

        let store = LinkedInSessionStore(tokenStore: tokenStore)

        #expect(!store.isConnected)
        #expect(tokenStore.savedToken == nil)
    }

    private static func token(memberID: String) -> LinkedInToken {
        token(memberID: memberID, expiresIn: nil, connectedAt: .now)
    }

    private static func token(memberID: String, expiresIn: Int?, connectedAt: Date) -> LinkedInToken {
        LinkedInToken(
            accessToken: "access-token",
            tokenType: "Bearer",
            scope: nil,
            expiresIn: expiresIn,
            profile: LinkedInProfile(
                memberID: memberID,
                name: "Katerina Bletsch",
                pictureURL: nil,
                email: nil,
                headline: nil,
                localizedHeadline: nil
            ),
            connectedAt: connectedAt
        )
    }
}

private final class InMemoryTokenStore: LinkedInTokenStore {
    var savedToken: LinkedInToken?

    func load() -> LinkedInToken? {
        savedToken
    }

    func save(_ token: LinkedInToken) -> Bool {
        savedToken = token
        return true
    }

    func clear() {
        savedToken = nil
    }
}
