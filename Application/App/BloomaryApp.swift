import SwiftUI
import UIKit
import UserNotifications

@main
struct BloomaryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: AppContainer
    private let configuration: AppConfiguration
    @StateObject private var draftStore: DraftStore
    @StateObject private var linkedInSessionStore: LinkedInSessionStore
    @StateObject private var aiSettingsStore: AISettingsStore
    @StateObject private var syncSettingsStore: SyncSettingsStore

    init() {
        let configuration = AppConfiguration.load()
        CrashReporter.start(configuration: configuration.observability)
        AppTelemetry.start(configuration: configuration.observability)
        AppTelemetry.track(.appOpened)
        let container = AppContainer(configuration: configuration)
        self.configuration = configuration
        self.container = container
        AppDelegate.container = container
        _draftStore = StateObject(wrappedValue: container.draftStore)
        _linkedInSessionStore = StateObject(wrappedValue: container.linkedInSessionStore)
        _aiSettingsStore = StateObject(wrappedValue: container.aiSettingsStore)
        _syncSettingsStore = StateObject(wrappedValue: container.syncSettingsStore)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(
                editorViewModel: container.editorViewModel,
                draftsViewModel: container.draftsViewModel,
                accountViewModel: container.accountViewModel,
                aiSettingsStore: aiSettingsStore,
                syncSettingsStore: syncSettingsStore,
                feedbackService: container.feedbackService,
                purchaseCoordinator: container.purchaseCoordinator,
                notificationTokenService: container.notificationTokenService,
                configuration: configuration
            )
                .environmentObject(draftStore)
                .environmentObject(linkedInSessionStore)
                .tint(AppStyle.green)
                .onOpenURL { url in
                    _ = container.authService.handleCallbackURL(url)
                }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var container: AppContainer?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard let container = Self.container else { return }
        Task { await container.notificationTokenService.receivedDeviceToken(deviceToken, credential: container.linkedInSessionStore.postCredential) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppTelemetry.track(.notificationSyncFailed)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
