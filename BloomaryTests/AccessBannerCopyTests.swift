import Foundation
import Testing
@testable import Bloomary

struct AccessBannerCopyTests {
    private let endedOn = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func lapsedTrialNamesTheTrial() {
        let date = AccessBannerCopy.formatted(endedOn)
        #expect(AccessBannerCopy.lapsed(subscriptionSource: "trial", endedOn: endedOn) == "Your 14-day trial ended on \(date). Your drafts are read-only.")
    }

    @Test
    func lapsedSubscriptionNamesTheSubscription() {
        let date = AccessBannerCopy.formatted(endedOn)
        #expect(AccessBannerCopy.lapsed(subscriptionSource: "apple", endedOn: endedOn) == "Your subscription ended on \(date). Your drafts are read-only.")
        #expect(AccessBannerCopy.lapsed(subscriptionSource: "paddle", endedOn: endedOn) == "Your subscription ended on \(date). Your drafts are read-only.")
    }

    @Test
    func scheduledPostsStillPublish() {
        let date = AccessBannerCopy.formatted(endedOn)
        #expect(AccessBannerCopy.scheduledStillPublish(lapsedOn: endedOn) == "Posts you scheduled before \(date) will still publish.")
    }
}
