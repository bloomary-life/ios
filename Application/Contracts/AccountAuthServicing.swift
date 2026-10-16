import Foundation

/// Auth surface the account presentation layer depends on. Keeps
/// `AccountViewModel` testable without `ASWebAuthenticationSession`/network.
@MainActor
protocol AccountAuthServicing {
    func signIn() async throws -> LinkedInToken
    func disconnect(memberID: String, accessToken: String) async throws
    func deleteAccount(memberID: String, accessToken: String) async throws
    func requireFreshSignInOnce()
}
