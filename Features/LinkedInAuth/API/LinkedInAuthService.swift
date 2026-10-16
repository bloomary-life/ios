import Foundation
import Foundation

enum LinkedInAuthError: LocalizedError {
    case invalidStartURL
    case missingWindow
    case cancelled
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidStartURL:
            return "LinkedIn authorization URL is invalid."
        case .missingWindow:
            return "Cannot open LinkedIn authorization."
        case .cancelled:
            return "LinkedIn authorization was cancelled."
        case .timedOut:
            return "LinkedIn authorization timed out."
        case .server(let message):
            return message
        }
    }
}

@MainActor
final class LinkedInAuthService {
    private let apiBaseURL: URL
    private let callbackURLScheme: String
    private let tokenStore: LinkedInTokenStore
    private let presenter: AuthorizationPresenter
    private let defaults: UserDefaults
    private let callbackURLHost = "linkedin-connected"
    private let pendingStateKey: String
    private let freshSignInKey: String
    private var signInTask: Task<LinkedInToken, Error>?

    init(apiBaseURL: URL, callbackURLScheme: String, tokenStore: LinkedInTokenStore, presenter: AuthorizationPresenter, defaults: UserDefaults = .standard) {
        self.apiBaseURL = apiBaseURL
        self.pendingStateKey = "linkedin.pendingState." + (apiBaseURL.host ?? "unknown")
        self.freshSignInKey = "linkedin.requiresFreshSignIn." + (apiBaseURL.host ?? "unknown")
        self.callbackURLScheme = callbackURLScheme
        self.tokenStore = tokenStore
        self.presenter = presenter
        self.defaults = defaults
    }

    @MainActor
    func signIn() async throws -> LinkedInToken {
        if let signInTask {
            return try await signInTask.value
        }
        let task = Task { @MainActor in
            try await self.performSignIn()
        }
        signInTask = task
        do {
            let token = try await task.value
            signInTask = nil
            return token
        } catch {
            signInTask = nil
            throw error
        }
    }

    @MainActor
    private func performSignIn() async throws -> LinkedInToken {
        defaults.removeObject(forKey: pendingStateKey)
        let start = try await startFlow()
        defaults.set(start.state, forKey: pendingStateKey)
        do {
            guard let token = try await presentAndPoll(url: start.authURL) else {
                throw LinkedInAuthError.timedOut
            }
            return token
        } catch {
            defaults.removeObject(forKey: pendingStateKey)
            throw error
        }
    }

    /// Runs the authorization sheet and the token poll concurrently.
    ///
    /// The callback page's redirect target is server configuration, and
    /// `SFSafariViewController` cannot hand a custom-scheme redirect back to the
    /// app, so the deep link can never be a requirement: the poll is the only
    /// reliable source of the token. The sheet closes as soon as the flow
    /// resolves; the user tapping Done still cancels sign-in.
    @MainActor
    private func presentAndPoll(url: URL) async throws -> LinkedInToken? {
        let poll = Task { try await completePendingSignIn() }
        defer { poll.cancel() }

        return try await withThrowingTaskGroup(of: SignInStep.self) { group in
            group.addTask { .polled(try await poll.value) }
            group.addTask { try await self.presentAuthorization(url: url) }
            do {
                while let step = try await group.next() {
                    guard case .polled(let token) = step else {
                        poll.cancel()
                        throw LinkedInAuthError.cancelled
                    }
                    group.cancelAll()
                    presenter.cancel()
                    return token
                }
                throw LinkedInAuthError.timedOut
            } catch {
                poll.cancel()
                group.cancelAll()
                presenter.cancel()
                throw error
            }
        }
    }

    private func presentAuthorization(url: URL) async throws -> SignInStep {
        try await presenter.present(url: url)
        return .sheetClosed
    }

    func disconnect(memberID: String, accessToken: String) async throws {
        let body = DisconnectRequest(linkedInID: memberID)
        var request = URLRequest(url: apiBaseURL.appending(path: "/api/linkedin/disconnect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.app.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func deleteAccount(memberID: String, accessToken: String) async throws {
        let body = DisconnectRequest(linkedInID: memberID)
        var request = URLRequest(url: apiBaseURL.appending(path: "/api/account/delete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.app.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func requireFreshSignInOnce() {
        defaults.set(true, forKey: freshSignInKey)
    }

    @MainActor
    func handleCallbackURL(_ url: URL) -> Bool {
        guard url.scheme == callbackURLScheme, url.host == callbackURLHost else { return false }
        presenter.complete(with: url)
        return true
    }

    private func startFlow() async throws -> StartResponse {
        var components = URLComponents(url: apiBaseURL.appending(path: "/api/linkedin/cli/start"), resolvingAgainstBaseURL: false)
        if defaults.bool(forKey: freshSignInKey) {
            components?.queryItems = [URLQueryItem(name: "fresh", value: "1")]
        }
        guard let url = components?.url else { throw LinkedInAuthError.invalidStartURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder.app.decode(StartResponse.self, from: data)
    }

    private func completePendingSignIn() async throws -> LinkedInToken? {
        guard let state = defaults.string(forKey: pendingStateKey) else { return nil }
        do {
            let token = try await pollResult(state: state)
            defaults.removeObject(forKey: pendingStateKey)
            defaults.removeObject(forKey: freshSignInKey)
            guard tokenStore.save(token) else {
                throw LinkedInAuthError.server("LinkedIn token could not be saved.")
            }
            return token
        } catch LinkedInAuthError.timedOut {
            defaults.removeObject(forKey: pendingStateKey)
            throw LinkedInAuthError.timedOut
        } catch let error as URLError {
            throw error
        } catch {
            defaults.removeObject(forKey: pendingStateKey)
            throw error
        }
    }

    private func pollResult(state: String) async throws -> LinkedInToken {
        // Polling starts while the authorization sheet is open, so this budget has to cover
        // the LinkedIn consent screen as well: 45 × 10s ≈ 7.5min. Keep the request count low —
        // /api/linkedin/cli/result is capped at 300 requests per IP per day.
        for _ in 0..<45 {
            var components = URLComponents(url: apiBaseURL.appending(path: "/api/linkedin/cli/result"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "wait", value: "10")
            ]
            guard let url = components?.url else { throw LinkedInAuthError.invalidStartURL }
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response, data: data)

            let envelope = try JSONDecoder.app.decode(ResultEnvelope.self, from: data)
            switch envelope.status {
            case "done":
                if let token = envelope.token {
                    return token
                }
                throw LinkedInAuthError.server("LinkedIn token is missing.")
            case "pending":
                continue
            case "error":
                throw LinkedInAuthError.server(envelope.errorDescription ?? envelope.error ?? "LinkedIn authorization failed.")
            default:
                throw LinkedInAuthError.server("Unexpected LinkedIn authorization status.")
            }
        }
        throw LinkedInAuthError.timedOut
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder.app.decode(APIErrorResponse.self, from: data) {
                throw LinkedInAuthError.server(apiError.errorDescription ?? apiError.error)
            }
            throw LinkedInAuthError.server("Request failed with status \(http.statusCode).")
        }
    }
}

struct StartResponse: Codable {
    let authURL: URL
    let state: String
    let redirectURI: URL
    let pollURL: String

    enum CodingKeys: String, CodingKey {
        case authURL = "authUrl"
        case state
        case redirectURI = "redirectUri"
        case pollURL = "pollUrl"
    }
}

struct ResultEnvelope: Codable {
    let status: String
    let token: LinkedInToken?
    let error: String?
    let errorDescription: String?
    let httpStatus: Int?
    let upstreamBody: String?

    enum CodingKeys: String, CodingKey {
        case status
        case token
        case error
        case errorDescription
        case httpStatus
        case upstreamBody
    }
}

struct APIErrorResponse: Codable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription
    }
}

private enum SignInStep {
    case polled(LinkedInToken?)
    case sheetClosed
}

private struct DisconnectRequest: Encodable {
    let linkedInID: String

    enum CodingKeys: String, CodingKey {
        case linkedInID = "linkedInId"
    }
}

extension LinkedInAuthService: AccountAuthServicing {}
