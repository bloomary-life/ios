import Foundation
import Testing
@testable import Bloomary

@MainActor
@Suite(.serialized)
struct EntitlementServiceTests {
    @Test
    func refreshImmediatelyAfterInvalidationUsesANewRequest() async throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let credential = LinkedInPostCredential(accessToken: "token", memberID: "member-1")
        let oldRequest = Task { try? await service.entitlement(credential: credential) }
        defer { oldRequest.cancel() }
        try await waitForFirstRequest()

        service.clearCache(memberID: credential.memberID)
        let refreshed = try await service.entitlement(credential: credential, forceRefresh: true)
        _ = await oldRequest.value
        let cached = try await service.entitlement(credential: credential)

        #expect(refreshed.isPro)
        #expect(cached == refreshed)
        #expect(EntitlementURLProtocol.requestCount == 2)
    }

    @Test
    func concurrentRefreshesShareOneRequest() async throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }
        let credential = LinkedInPostCredential(accessToken: "token", memberID: "member-1")
        async let first = service.entitlement(credential: credential, forceRefresh: true)
        async let second = service.entitlement(credential: credential, forceRefresh: true)
        try await waitForFirstRequest()
        EntitlementURLProtocol.releaseFirst()

        let results = try await [first, second]
        #expect(results[0].isPro && results[1].isPro)
        #expect(EntitlementURLProtocol.requestCount == 1)
    }

    @Test(arguments: [false, true])
    func cachedProIsReplacedAfterExpiryOrForcedRefresh(forceRefresh: Bool) async throws {
        let cached = Entitlement(isPro: true, draftLimit: 50, postCount: 1,
                                 accessUntil: Date().addingTimeInterval(forceRefresh ? 3600 : -1))
        let (service, cleanup) = try makeService(serverIsPro: false, cached: cached)
        defer { cleanup() }
        let credential = LinkedInPostCredential(accessToken: "token", memberID: "member-1")
        let refresh = Task { try await service.entitlement(credential: credential, forceRefresh: forceRefresh) }
        defer { refresh.cancel() }
        try await waitForFirstRequest()
        EntitlementURLProtocol.releaseFirst()

        let current = try await refresh.value
        #expect(!current.isPro)
        let cachedResult = try await service.entitlement(credential: credential)
        #expect(cachedResult == current)
        #expect(EntitlementURLProtocol.requestCount == 1)
    }

    @Test
    func expiredAccessDecodesAsLapsedTierInsteadOfThrowing() async throws {
        let lapsed = Entitlement(isPro: false, draftLimit: 5, postCount: 1,
                                 accessUntil: Date().addingTimeInterval(-60), subscriptionSource: "trial", tier: "lapsed")
        let (service, cleanup) = try makeService(serverEntitlement: lapsed)
        defer { cleanup() }
        let credential = LinkedInPostCredential(accessToken: "token", memberID: "member-1")
        let refresh = Task { try await service.entitlement(credential: credential, forceRefresh: true) }
        try await waitForFirstRequest()
        EntitlementURLProtocol.releaseFirst()

        let current = try await refresh.value
        #expect(current.accessTier == .lapsed)
        #expect(current.subscriptionSource == "trial")
        let cachedResult = try await service.entitlement(credential: credential)
        #expect(cachedResult == current)
        #expect(EntitlementURLProtocol.requestCount == 1)
    }

    @Test
    func trialTierDecodesWithoutIsPro() throws {
        let json = #"{"tier":"trial","isPro":false,"needsSignature":false,"draftLimit":50,"postCount":0}"#
        let entitlement = try JSONDecoder.app.decode(Entitlement.self, from: Data(json.utf8))
        #expect(entitlement.accessTier == .trial)
        #expect(entitlement.accessTier.hasAccess)
    }

    private struct Cached: Encodable {
        let fetchedAt = Date()
        let entitlement: Entitlement
    }

    private func makeService(serverIsPro: Bool = true, serverEntitlement: Entitlement? = nil, cached: Entitlement? = nil) throws -> (EntitlementService, () -> Void) {
        EntitlementURLProtocol.reset(isPro: serverIsPro, entitlement: serverEntitlement)
        let name = "EntitlementServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        if let cached {
            defaults.set(try JSONEncoder.app.encode(Cached(entitlement: cached)), forKey: "bloomary_entitlement_entitlement.test_member-1")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EntitlementURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = EntitlementService(apiBaseURL: URL(string: "https://entitlement.test")!, defaults: defaults, session: session)
        return (service, { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: name) })
    }

    private func waitForFirstRequest() async throws {
        for _ in 0..<100 {
            if EntitlementURLProtocol.requestCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
}

private final class EntitlementURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var first: EntitlementURLProtocol?
    private static var pro = true
    private static var payload: Entitlement?

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    static func reset(isPro: Bool, entitlement: Entitlement? = nil) {
        lock.lock(); defer { lock.unlock() }; count = 0; first = nil; pro = isPro; payload = entitlement
    }

    static func releaseFirst() {
        lock.lock()
        let pending = first
        first = nil
        lock.unlock()
        pending?.succeed()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "entitlement.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let held = Self.count == 1
        if held { Self.first = self }
        Self.lock.unlock()
        if !held { succeed() }
    }

    private func succeed() {
        Self.lock.lock()
        let isPro = Self.pro
        let payload = Self.payload
        Self.lock.unlock()
        let data = try! JSONEncoder.app.encode(payload ?? Entitlement(isPro: isPro,
                                                                     draftLimit: isPro ? 50 : 5, postCount: 1, accessUntil: nil))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
