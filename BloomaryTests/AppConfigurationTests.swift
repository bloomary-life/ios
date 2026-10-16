import Foundation
import Testing
@testable import Bloomary

@Suite(.serialized)
struct AppConfigurationTests {
    @Test
    func decodesRuntimeConfiguration() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>api</key>
            <dict>
                <key>baseURL</key>
                <string>https://api.bloomary.life</string>
            </dict>
            <key>linkedIn</key>
            <dict>
                <key>callbackURLScheme</key>
                <string>bloomary</string>
            </dict>
            <key>storage</key>
            <dict>
                <key>draftsKey</key>
                <string>bloomary_drafts</string>
                <key>linkedInTokenKey</key>
                <string>bloomary_linkedin_token</string>
            </dict>
            <key>scheduling</key>
            <dict>
                <key>maxAheadDays</key>
                <integer>21</integer>
            </dict>
        </dict>
        </plist>
        """.utf8)

        let configuration = try PropertyListDecoder().decode(AppConfiguration.self, from: data)

        #expect(configuration.api.baseURL.absoluteString == "https://api.bloomary.life")
        #expect(configuration.linkedIn.callbackURLScheme == "bloomary")
        #expect(configuration.storage.draftsKey == "bloomary_drafts")
        #expect(configuration.storage.linkedInTokenKey == "bloomary_linkedin_token")
        #expect(configuration.scheduling.maxAheadDays == 21)
        #expect(configuration.observability.sentryDSN.isEmpty)
        #expect(configuration.observability.sentryEnvironment == "production")
        #expect(configuration.observability.sentryTracesSampleRate == 0.1)
        #expect(configuration.observability.telemetryDeckAppID.isEmpty)
        #expect(configuration.observability.telemetryDeckNamespace.isEmpty)
    }

    @Test
    func decodesObservabilityConfiguration() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>api</key>
            <dict>
                <key>baseURL</key>
                <string>https://api.bloomary.life</string>
            </dict>
            <key>linkedIn</key>
            <dict>
                <key>callbackURLScheme</key>
                <string>bloomary</string>
            </dict>
            <key>storage</key>
            <dict>
                <key>draftsKey</key>
                <string>bloomary_drafts</string>
                <key>linkedInTokenKey</key>
                <string>bloomary_linkedin_token</string>
            </dict>
            <key>observability</key>
            <dict>
                <key>sentryDSN</key>
                <string>https://example@sentry.io/1</string>
                <key>sentryEnvironment</key>
                <string>production</string>
                <key>sentryTracesSampleRate</key>
                <real>0.1</real>
                <key>telemetryDeckAppID</key>
                <string>00000000-0000-0000-0000-000000000000</string>
                <key>telemetryDeckNamespace</key>
                <string>eu.dailymind</string>
            </dict>
        </dict>
        </plist>
        """.utf8)

        let configuration = try PropertyListDecoder().decode(AppConfiguration.self, from: data)

        #expect(configuration.observability.telemetryDeckAppID == "00000000-0000-0000-0000-000000000000")
        #expect(configuration.observability.telemetryDeckNamespace == "eu.dailymind")
        #expect(configuration.observability.sentryEnvironment == "production")
    }

    @Test
    func stageConfigurationSeparatesDiagnosticsFromProduction() {
        let previous = BackendEnvironment.selected
        defer { BackendEnvironment.selected = previous }
        BackendEnvironment.selected = .test

        let configuration = AppConfiguration.load()

        #expect(configuration.api.baseURL == configuration.api.testBaseURL)
        #expect(configuration.activeEnvironment == .test)
        #expect(configuration.observability.sentryEnvironment == "stage")
        #expect(configuration.observability.telemetryDeckAppID.isEmpty)
    }

    @Test
    func bundledConfigurationUsesRuntimeBackend() {
        let previous = BackendEnvironment.selected
        defer { BackendEnvironment.selected = previous }
        BackendEnvironment.selected = .production
        let configuration = AppConfiguration.load()

        #if targetEnvironment(simulator)
        #expect(configuration.api.baseURL == AppConfiguration.simulatorAPIBaseURL)
        #else
        #expect(configuration.api.baseURL == AppConfiguration.fallback.api.baseURL)
        #endif
        #expect(configuration.storage.draftsKey == "bloomary_drafts.\(configuration.api.baseURL.host!)")
        #expect(configuration.storage.linkedInTokenKey == "bloomary_linkedin_token.\(configuration.api.baseURL.host!)")
        #expect(configuration.scheduling.maxAheadDays == 31)
        #expect(configuration.observability.sentryEnvironment == "production")
        #expect(configuration.activeEnvironment == .production)
    }
}
