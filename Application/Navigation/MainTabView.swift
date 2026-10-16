import SwiftUI
import OSLog

struct MainTabView: View {
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var linkedInSessionStore: LinkedInSessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 2
    @State private var opensDraftInEditor = false
    @State private var showsFeedback = false
    @State private var showsPurchase = false
    @State private var showsPostToast = false
    @State private var feedbackButtonPosition: CGPoint?
    @State private var feedbackButtonDragStart: CGPoint?
    @State private var pendingInsightsTemplate = false
    @ObservedObject var editorViewModel: EditorViewModel
    let draftsViewModel: DraftsViewModel
    let accountViewModel: AccountViewModel
    let aiSettingsStore: AISettingsStore
    let syncSettingsStore: SyncSettingsStore
    let feedbackService: FeedbackService
    let purchaseCoordinator: PurchaseCoordinator
    var notificationTokenService: NotificationTokenService? = nil
    let configuration: AppConfiguration

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack {
                InsightsView(hasUnsavedChanges: draftStore.hasUnsavedChanges) {
                    if draftStore.hasUnsavedChanges {
                        pendingInsightsTemplate = true
                    } else {
                        applyInsightsTemplate()
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { accessBanner }
            }
            .tabItem {
                Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(0)

            NavigationStack {
                DraftsView(viewModel: draftsViewModel) {
                    openDraftInEditor()
                }
                .safeAreaInset(edge: .top, spacing: 0) { accessBanner }
            }
            .tabItem {
                Label("Drafts", systemImage: "doc.text")
            }
            .tag(1)

            NavigationStack {
                EditorView(viewModel: editorViewModel) {
                    selectedTab = 1
                } onPostSucceeded: {
                    showPostedToast()
                } onShowPurchase: {
                    showsPurchase = true
                }
                .safeAreaInset(edge: .top, spacing: 0) { accessBanner }
            }
            .tabItem {
                Label("Editor", systemImage: "square.and.pencil")
            }
            .tag(2)

            NavigationStack {
                AccountSettingsView(
                    viewModel: accountViewModel,
                    feedbackService: feedbackService,
                    aiSettingsStore: aiSettingsStore,
                    syncSettingsStore: syncSettingsStore,
                    isPro: draftStore.isPro,
                    onShowPurchase: { showsPurchase = true }
                )
                .safeAreaInset(edge: .top, spacing: 0) { accessBanner }
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(3)
        }
        .overlay {
            GeometryReader { proxy in
                let defaultPosition = defaultFeedbackButtonPosition(in: proxy.size)
                Image(systemName: "ladybug")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 52, height: 52)
                    .background(AppStyle.coral)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .accessibilityLabel("Send feedback")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openFeedback() }
                .position(feedbackButtonPosition ?? defaultPosition)
                .onTapGesture {
                    openFeedback()
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = feedbackButtonDragStart ?? feedbackButtonPosition ?? defaultPosition
                            feedbackButtonDragStart = start
                            feedbackButtonPosition = clampedFeedbackButtonPosition(
                                CGPoint(
                                    x: start.x + value.translation.width,
                                    y: start.y + value.translation.height
                                ),
                                in: proxy.size
                            )
                        }
                        .onEnded { _ in
                            feedbackButtonDragStart = nil
                        }
                )
            }
        }
        .overlay(alignment: .top) {
            if configuration.activeEnvironment == .test || linkedInSessionStore.isDemo {
                HStack(spacing: 6) {
                    if configuration.activeEnvironment == .test {
                        Text("TEST")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(AppStyle.coral)
                            .clipShape(Capsule())
                    }
                    if linkedInSessionStore.isDemo {
                        Text("DEMO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.purple)
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 6)
            }
        }
        .overlay(alignment: .top) {
            if showsPostToast {
                Text("Posted to LinkedIn")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppStyle.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppStyle.panel.opacity(0.96))
                    .clipShape(Capsule())
                    .shadow(color: AppStyle.ink.opacity(0.12), radius: 18, x: 0, y: 8)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showsFeedback) {
            NavigationStack {
                FeedbackView(feedbackService: feedbackService)
            }
        }
        .sheet(isPresented: $showsPurchase) {
            PurchaseView(
                purchaseService: purchaseCoordinator.purchaseService,
                credential: linkedInSessionStore.postCredential,
                isPro: draftStore.isPro,
                subscriptionSource: draftStore.subscriptionSource
            ) {
                refreshEntitlement()
            }
        }
        .onAppear {
            PerformanceSignposts.appLaunchComplete()
            draftStore.setSession(linkedInSessionStore.token)
            Task { await notificationTokenService?.configure(credential: linkedInSessionStore.postCredential) }
            startPurchaseSync()
            syncCurrentPurchases()
            refreshEntitlement()
        }
        .onChange(of: linkedInSessionStore.token) { _, token in
            draftStore.setSession(token)
            Task { await notificationTokenService?.configure(credential: linkedInSessionStore.postCredential) }
            startPurchaseSync()
            syncCurrentPurchases()
            refreshEntitlement()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            linkedInSessionStore.expireIfNeeded()
            Task { await notificationTokenService?.configure(credential: linkedInSessionStore.postCredential) }
            syncCurrentPurchases()
            refreshEntitlement()
            draftStore.refreshFromRemote()
            Task { await editorViewModel.refreshScheduleStatus() }
        }
        .task {
            while !Task.isCancelled {
                if scenePhase == .active { await editorViewModel.refreshScheduleStatus() }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .alert("Post published", isPresented: $editorViewModel.showsSchedulePublishedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your scheduled post is now live on LinkedIn.")
        }
        .alert("Scheduled post needs attention", isPresented: $editorViewModel.showsScheduleFailureAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(editorViewModel.scheduleFailureMessage ?? "Reconnect LinkedIn to update your token, then schedule the post again.")
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(
            get: { draftStore.pendingDraft != nil },
            set: { if !$0 { draftStore.pendingDraft = nil } }
        ), titleVisibility: .visible) {
            Button("Discard and open draft", role: .destructive) {
                draftStore.confirmOpenDraft()
                selectedTab = 2
            }
            Button("Keep editing", role: .cancel) { draftStore.pendingDraft = nil }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $pendingInsightsTemplate, titleVisibility: .visible) {
            Button("Discard and start template", role: .destructive) {
                pendingInsightsTemplate = false
                applyInsightsTemplate()
            }
            Button("Keep editing", role: .cancel) { pendingInsightsTemplate = false }
        }
    }

    /// Persistent banners from `docs/product/tiers.md` "Copy" rows 1–2, 6.
    /// Inset under each tab's navigation bar so it never covers a screen title.
    /// Signed out gets no banner: local writing works without an account.
    @ViewBuilder
    private var accessBanner: some View {
        if linkedInSessionStore.token != nil && draftStore.isLapsed {
            let hasPendingSchedules = draftStore.scheduledPosts.contains { ["pending", "processing", "retry"].contains($0.status) }
            AccessBanner(
                message: AccessBannerCopy.lapsed(subscriptionSource: draftStore.subscriptionSource, endedOn: draftStore.accessUntil),
                detail: hasPendingSchedules ? draftStore.accessUntil.map(AccessBannerCopy.scheduledStillPublish(lapsedOn:)) : nil,
                actionTitle: "See plans"
            ) {
                showsPurchase = true
            }
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { selectTab($0) }
        )
    }

    private func selectTab(_ tab: Int) {
        opensDraftInEditor = false
        selectedTab = tab
    }

    private func openDraftInEditor() {
        opensDraftInEditor = true
        selectedTab = 2
    }

    private func applyInsightsTemplate() {
        draftStore.startNewPost()
        draftStore.editorText = "I used to think my story was too ordinary to post.\n\nThen I looked at what actually changed:\n\n- a problem I survived\n- a skill I built\n- a result I can prove\n- a person I can help now\n\nHere is the lesson:"
        selectedTab = 2
    }

    private func defaultFeedbackButtonPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: 44, y: max(92, size.height * 0.82))
    }

    private func clampedFeedbackButtonPosition(_ position: CGPoint, in size: CGSize) -> CGPoint {
        let radius: CGFloat = 34
        return CGPoint(
            x: min(max(position.x, radius), size.width - radius),
            y: min(max(position.y, radius), size.height - radius)
        )
    }

    private func openFeedback() {
        showsFeedback = true
        AppTelemetry.track(.feedbackOpened)
    }

    private func showPostedToast() {
        selectedTab = 0
        withAnimation(.easeInOut(duration: 0.2)) {
            showsPostToast = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeInOut(duration: 0.4)) {
                showsPostToast = false
            }
        }
    }

    private func startPurchaseSync() {
        purchaseCoordinator.startObservingTransactions(credentialProvider: {
            linkedInSessionStore.postCredential
        }, onSynced: { credential in
            guard linkedInSessionStore.postCredential == credential else { return }
            refreshEntitlement()
        })
    }

    private func syncCurrentPurchases() {
        guard let credential = linkedInSessionStore.postCredential else { return }
        Task {
            do {
                let didSync = try await purchaseCoordinator.syncCurrentEntitlements(credential: credential)
                guard linkedInSessionStore.postCredential == credential, didSync else { return }
                refreshEntitlement()
            } catch {
                guard linkedInSessionStore.postCredential == credential else { return }
                let failure = error as NSError
                Logger(subsystem: "com.dailymind.bloomary", category: "Purchases").error("Foreground purchase sync failed: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
                AppTelemetry.track(.purchaseSyncFailed, parameters: ["reason": "foreground"])
                draftStore.statusMessage = "Purchase verification failed. Open Settings and restore purchases to retry."
            }
        }
    }

    private func refreshEntitlement() {
        guard let credential = linkedInSessionStore.postCredential else {
            draftStore.setEntitlement(isPro: false, postCount: 0)
            return
        }

        Task {
            let entitlement = await purchaseCoordinator.refreshEntitlement(credential: credential)
            await MainActor.run {
                guard linkedInSessionStore.postCredential == credential else { return }
                if entitlement == nil { draftStore.statusMessage = "Plan status unavailable. Reconnect or refresh Settings." }
                draftStore.setEntitlement(
                    isPro: entitlement?.isPro ?? false,
                    postCount: entitlement?.postCount ?? 0,
                    tier: entitlement?.accessTier,
                    subscriptionSource: entitlement?.subscriptionSource,
                    accessUntil: entitlement?.accessUntil,
                    maxDraftBodyRunes: entitlement?.maxDraftBodyRunes,
                    maxImageBytes: entitlement?.maxImageBytes
                )
            }
        }
    }
}
