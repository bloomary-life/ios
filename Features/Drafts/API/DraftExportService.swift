import Foundation

// Export is open in every access state, lapsed included: docs/product/tiers.md "Export".
struct DraftExportService: Sendable {
    let apiBaseURL: URL
    var session: URLSession = .shared

    /// Downloads the zip of every server-side draft and returns its local file URL.
    func export(memberID: String, accessToken: String) async throws -> URL {
        let url = apiBaseURL.appending(path: "/api/drafts/export")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "memberId", value: memberID)]
        var request = URLRequest(url: components?.url ?? url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SyncedDraftsError.server("Draft export failed.")
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "bloomary-drafts.zip")
        try data.write(to: file, options: .atomic)
        return file
    }
}
