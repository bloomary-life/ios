import Foundation
import Testing
@testable import Bloomary

struct AppAccountTokenTests {
    @Test
    @MainActor
    func appAccountTokenMatchesBackendUUIDV5() {
        let service = StoreKitPurchaseService(apiBaseURL: URL(string: "https://api.bloomary.life")!)

        #expect(service.appAccountToken(memberID: "member-1").uuidString.lowercased() == "4f1d124b-b921-5973-b271-9475fbe9ee95")
    }
}
