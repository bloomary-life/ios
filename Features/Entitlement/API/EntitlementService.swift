import Foundation
import OSLog

enum EntitlementError: LocalizedError {
    case missingAuth
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            return "LinkedIn connection is required."
        case .server(let message):
            return message
        }
    }
}

/// Server-computed access state (`docs/product/tiers.md`). Render it, never derive it.
enum EntitlementTier: String, Codable {
    case trial, pro, lapsed

    /// "trial or pro". `isPro` is false during trial, so gates must use this.
    var hasAccess: Bool { self != .lapsed }
}

struct Entitlement: Codable, Equatable {
    let isPro: Bool
    let draftLimit: Int
    let postCount: Int
    let accessUntil: Date?
    var subscriptionSource: String? = nil
    var maxDraftBodyRunes: Int? = nil
    var maxImageBytes: Int? = nil
    /// Raw server value; kept as a string so an unknown future tier does not fail decoding.
    var tier: String? = nil

    /// Falls back to `isPro` only for responses cached before the server sent `tier`.
    var accessTier: EntitlementTier {
        tier.flatMap(EntitlementTier.init(rawValue:)) ?? (isPro ? .pro : .lapsed)
    }
}

@MainActor
final class EntitlementService {
    private let apiBaseURL: URL
    private let defaults: UserDefaults
    private let cacheTTL: TimeInterval
    private let session: URLSession
    private var inFlightTasks: [String: (id: UUID, task: Task<Entitlement, Error>)] = [:]

    init(apiBaseURL: URL, defaults: UserDefaults = .standard, cacheTTL: TimeInterval = 300, session: URLSession = .shared) {
        self.apiBaseURL = apiBaseURL
        self.defaults = defaults
        self.cacheTTL = cacheTTL
        self.session = session
    }

    func entitlement(credential: LinkedInPostCredential, forceRefresh: Bool = false) async throws -> Entitlement {
        guard !credential.accessToken.isEmpty, !credential.memberID.isEmpty else {
            throw EntitlementError.missingAuth
        }
        if !forceRefresh, let cached = cachedEntitlement(memberID: credential.memberID), cached.isFresh(ttl: cacheTTL),
           cached.entitlement.accessTier == .lapsed || (cached.entitlement.accessUntil.map({ $0 > Date() }) ?? true) {
            return cached.entitlement
        }

        let requestID = credential.memberID + ":" + credential.accessToken
        if let existing = inFlightTasks[requestID] {
            return try await existing.task.value
        }

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if inFlightTasks[requestID]?.id == taskID {
                    inFlightTasks.removeValue(forKey: requestID)
                }
            }
            do {
                return try await fetchEntitlement(credential: credential)
            } catch {
                // An invalidated request must not clear its replacement's cache.
                if inFlightTasks[requestID]?.id == taskID {
                    defaults.removeObject(forKey: cacheKey(memberID: credential.memberID))
                }
                throw error
            }
        }
        inFlightTasks[requestID] = (taskID, task)
        return try await task.value
    }

    private func fetchEntitlement(credential: LinkedInPostCredential) async throws -> Entitlement {
        var components = URLComponents(url: apiBaseURL.appending(path: "/api/entitlement"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "memberId", value: credential.memberID)]
        guard let url = components?.url else {
            throw EntitlementError.server("Entitlement load failed.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder.app.decode(EntitlementAPIError.self, from: data) {
                throw EntitlementError.server(apiError.errorDescription ?? apiError.error)
            }
            throw EntitlementError.server("Entitlement load failed.")
        }
        let entitlement = try JSONDecoder.app.decode(Entitlement.self, from: data)
        try Task.checkCancellation()
        cache(entitlement, memberID: credential.memberID)
        return entitlement
    }

    func clearCache(memberID: String) {
        for (key, entry) in inFlightTasks where key.hasPrefix(memberID + ":") {
            inFlightTasks.removeValue(forKey: key)
            entry.task.cancel()
        }
        defaults.removeObject(forKey: cacheKey(memberID: memberID))
    }

    private func cache(_ entitlement: Entitlement, memberID: String) {
        let cached = CachedEntitlement(fetchedAt: Date(), entitlement: entitlement)
        if let data = try? JSONEncoder.app.encode(cached) {
            defaults.set(data, forKey: cacheKey(memberID: memberID))
        }
    }

    private func cachedEntitlement(memberID: String) -> CachedEntitlement? {
        guard let data = defaults.data(forKey: cacheKey(memberID: memberID)) else {
            return nil
        }
        return try? JSONDecoder.app.decode(CachedEntitlement.self, from: data)
    }

    private func cacheKey(memberID: String) -> String {
        "bloomary_entitlement_\(apiBaseURL.host ?? "unknown")_\(memberID)"
    }
}

private struct CachedEntitlement: Codable {
    let fetchedAt: Date
    let entitlement: Entitlement

    func isFresh(ttl: TimeInterval) -> Bool {
        fetchedAt.addingTimeInterval(ttl) > Date()
    }
}

private struct EntitlementAPIError: Decodable {
    let error: String
    let errorDescription: String?
}
