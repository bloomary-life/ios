import Foundation
import OSLog

enum LinkedInPostError: LocalizedError {
    case emptyPost
    case missingAuth
    case authorizationExpired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyPost:
            return "Post is empty."
        case .missingAuth:
            return "Connect LinkedIn first."
        case .authorizationExpired:
            return "LinkedIn authorization expired. Connect LinkedIn again."
        case .server(let message):
            return message
        }
    }
}

final class LinkedInPostService: Sendable {
    private let apiBaseURL: URL

    init(apiBaseURL: URL) {
        self.apiBaseURL = apiBaseURL
    }

    func publish(text: String, credential: LinkedInPostCredential?, attachment: LinkedInPostAttachment? = nil, draftID: String? = nil) async throws -> PublishResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || attachment != nil else { throw LinkedInPostError.emptyPost }
        guard let credential, !credential.accessToken.isEmpty, !credential.memberID.isEmpty else {
            throw LinkedInPostError.missingAuth
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let builder = MultipartFormDataBuilder(boundary: boundary)
        var request = URLRequest(url: apiBaseURL.appending(path: "/api/linkedin/post"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        var fields = [
            "memberId": credential.memberID,
            "commentary": body,
            "timezone": TimeZone.current.identifier
        ]
        // The backend cancels this draft's schedule once the post is live.
        if let draftID { fields["draftId"] = draftID }
        request.httpBody = builder.body(
            fields: fields,
            file: attachment.map {
                MultipartFormFile(
                    fieldName: "attachment",
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    data: $0.data
                )
            }
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                throw LinkedInPostError.authorizationExpired
            }
            if let apiError = try? JSONDecoder.app.decode(PostAPIErrorResponse.self, from: data) {
                throw LinkedInPostError.server(apiError.errorDescription ?? apiError.error)
            }
            throw LinkedInPostError.server("LinkedIn post failed.")
        }

        let success = try? JSONDecoder.app.decode(PostSuccessResponse.self, from: data)
        return PublishResult(postID: success?.postId)
    }

    func schedule(draftID: UUID, wireID: String? = nil, reviewConfirmed: Bool = false, at date: Date, credential: LinkedInPostCredential?) async throws -> ScheduledPostResult {
        guard let credential, !credential.accessToken.isEmpty, !credential.memberID.isEmpty else { throw LinkedInPostError.missingAuth }
        var request = authorizedRequest(path: "/api/linkedin/schedule", credential: credential)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        request.httpBody = try JSONEncoder.app.encode(ScheduleRequest(reviewConfirmed: reviewConfirmed, draftId: wireID ?? draftID.uuidString.lowercased(), scheduledAt: formatter.string(from: date)))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.app.decode(ScheduledPostResult.self, from: data)
    }

    func unschedule(draftID: String, credential: LinkedInPostCredential?) async throws {
        guard let credential, !credential.accessToken.isEmpty, !credential.memberID.isEmpty else { throw LinkedInPostError.missingAuth }
        var components = URLComponents(url: apiBaseURL.appending(path: "/api/linkedin/schedule"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "memberId", value: credential.memberID), URLQueryItem(name: "draftId", value: draftID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func scheduleStatus(id: String, credential: LinkedInPostCredential?) async throws -> ScheduledPostResult {
        guard let credential, !credential.accessToken.isEmpty, !credential.memberID.isEmpty else { throw LinkedInPostError.missingAuth }
        var components = URLComponents(url: apiBaseURL.appending(path: "/api/linkedin/schedule/status"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "memberId", value: credential.memberID), URLQueryItem(name: "scheduleId", value: id)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.app.decode(ScheduledPostResult.self, from: data)
    }

    func scheduledPosts(credential: LinkedInPostCredential?) async throws -> [ScheduledPostResult] {
        guard let credential, !credential.accessToken.isEmpty, !credential.memberID.isEmpty else { throw LinkedInPostError.missingAuth }
        var request = authorizedRequest(path: "/api/linkedin/schedules", credential: credential)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.app.decode(ScheduledPostsResponse.self, from: data).schedules
    }

    private func authorizedRequest(path: String, credential: LinkedInPostCredential) -> URLRequest {
        var components = URLComponents(url: apiBaseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "memberId", value: credential.memberID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw LinkedInPostError.authorizationExpired }
        let apiError = try? JSONDecoder.app.decode(PostAPIErrorResponse.self, from: data)
        throw LinkedInPostError.server(apiError?.errorDescription ?? apiError?.error ?? "LinkedIn request failed.")
    }
}

struct LinkedInPostAttachment: Equatable {
    let data: Data
    let filename: String
    let mimeType: String
}

struct PublishResult: Equatable {
    let postID: String?
}

struct ScheduledPostResult: Decodable, Equatable {
    let scheduleId: String
    let draftId: String?
    let status: String
    let scheduledAt: String
    let message: String?
}

private struct ScheduledPostsResponse: Decodable {
    let schedules: [ScheduledPostResult]
}

private struct ScheduleRequest: Encodable {
    let reviewConfirmed: Bool
    let draftId: String
    let scheduledAt: String
}

private struct PostSuccessResponse: Decodable {
    let status: String?
    let postId: String?
}

struct LinkedInPostCredential: Equatable {
    let accessToken: String
    let memberID: String
}

private struct PostAPIErrorResponse: Codable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription
    }
}
