import Sentry
import Testing
@testable import Bloomary

struct ObservabilityTests {
    // Verifies: IOS-001
    @Test
    func testRunsNeverStartCrashReporting() {
        #expect(CrashReporter.isRunningTests)
        #expect(!SentrySDK.isEnabled)
    }
}
