import Foundation

/// Presents an external authorization URL and resumes with the callback URL.
/// Keeps the auth service free of UI presentation details.
@MainActor
protocol AuthorizationPresenter {
    @MainActor func present(url: URL) async throws
    func complete(with url: URL)
    func cancel()
}
