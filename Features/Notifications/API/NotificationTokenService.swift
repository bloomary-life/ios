import Foundation
import UIKit
import UserNotifications
import OSLog

enum NotificationTokenError: LocalizedError {
    case missingAuth
    case emptyToken
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            return "Connect LinkedIn first."
        case .emptyToken:
            return "Notification token is empty."
        case .server(let message):
            return message
        }
    }
}

@MainActor
final class NotificationTokenService {
    private let logger = Logger(subsystem: "com.dailymind.bloomary", category: "Notifications")
    private var configurationTask: Task<Void, Never>?
    private var desiredCredential: LinkedInPostCredential?
    private var registeredCredential: LinkedInPostCredential?
    private var deviceToken: Data?
    private let apiBaseURL: URL
    private let session: URLSession

    init(apiBaseURL: URL, session: URLSession = .shared) {
        self.apiBaseURL = apiBaseURL
        self.session = session
    }

    func configure(credential: LinkedInPostCredential?) async {
        desiredCredential = credential
        let previous = configurationTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.desiredCredential == credential else { return }
            await self.performConfigure(credential: credential)
        }
        configurationTask = task
        await task.value
    }

    private func performConfigure(credential: LinkedInPostCredential?) async {
        do {
            if let old = registeredCredential, old != credential, let deviceToken {
                try await register(token: deviceToken, credential: old, enabled: false)
                registeredCredential = nil
            }
            guard let credential else { return }
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                settings = await center.notificationSettings()
            }
            let enabled = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            if enabled && deviceToken == nil { UIApplication.shared.registerForRemoteNotifications() }
            if let deviceToken {
                try await register(token: deviceToken, credential: credential, enabled: enabled)
                registeredCredential = enabled ? credential : nil
            }
        } catch {
            logger.error("Notification permission or token synchronization failed: \(String(describing: type(of: error)), privacy: .public)")
            AppTelemetry.track(.notificationSyncFailed)
        }
    }

    func receivedDeviceToken(_ token: Data, credential: LinkedInPostCredential?) async {
        deviceToken = token
        await configure(credential: credential)
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    func register(token: Data, credential: LinkedInPostCredential, enabled: Bool = true) async throws {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        try await register(token: tokenString, credential: credential, enabled: enabled)
    }

    func register(token: String, credential: LinkedInPostCredential, enabled: Bool = true) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.accessToken.isEmpty, !credential.memberID.isEmpty else { throw NotificationTokenError.missingAuth }
        guard !token.isEmpty else { throw NotificationTokenError.emptyToken }

        var request = URLRequest(url: apiBaseURL.appending(path: "/api/notifications/token"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.app.encode(NotificationTokenRequest(
            memberId: credential.memberID,
            environment: Self.apnsEnvironment,
            platform: "ios",
            token: token,
            timezone: TimeZone.current.identifier,
            enabled: enabled
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder.app.decode(NotificationTokenAPIErrorResponse.self, from: data) {
                throw NotificationTokenError.server(apiError.errorDescription ?? apiError.error)
            }
            throw NotificationTokenError.server("Notification registration failed.")
        }
    }
}

private struct NotificationTokenRequest: Encodable {
    let memberId: String
    let environment: String
    let platform: String
    let token: String
    let timezone: String
    let enabled: Bool
}

private struct NotificationTokenAPIErrorResponse: Decodable {
    let error: String
    let errorDescription: String?
}
