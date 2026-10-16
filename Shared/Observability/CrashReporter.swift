import Foundation
import Sentry

enum CrashReporter {
    static func start(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let dsn = info["SentryDSN"] as? String ?? ""
        let environment = info["SentryEnvironment"] as? String ?? "production"
        let sampleRate = info["SentryTracesSampleRate"] as? Double ?? 0.1
        start(dsn: dsn, environment: environment, tracesSampleRate: sampleRate)
    }

    static func start(configuration: AppConfiguration.Observability) {
        start(
            dsn: configuration.sentryDSN,
            environment: configuration.sentryEnvironment,
            tracesSampleRate: configuration.sentryTracesSampleRate
        )
    }

    private static func start(dsn: String, environment: String, tracesSampleRate: Double) {
        let dsn = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.enableWatchdogTerminationTracking = true
            options.enableAutoPerformanceTracing = true
            options.tracesSampleRate = NSNumber(value: tracesSampleRate)
        }
    }
}
