import SwiftUI

struct AccountSettingsView: View {
    @State private var confirmsLegacyRecovery = false
    @ObservedObject var viewModel: AccountViewModel
    @State private var showsFeedback = false
    @State private var showsDemoCodeAlert = false
    @State private var demoCodeDraft = ""
    @State private var apiKeyDraft = ""
    @State private var isEditingAPIKey = false
    @State private var showsManageSubscriptions = false

    let feedbackService: FeedbackService?
    @ObservedObject var aiSettingsStore: AISettingsStore
    @ObservedObject var syncSettingsStore: SyncSettingsStore
    let isPro: Bool
    let onShowPurchase: () -> Void
    private var hasFeedback: Bool { feedbackService != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppStyle.ink)

                if viewModel.isConnected {
                    accountSection
                } else {
                    connectButton
                }

                aiSection
                if viewModel.hasOlderDeviceDrafts {
                    Button("Recover older device drafts") { confirmsLegacyRecovery = true }
                }

                if viewModel.isConnected {
                    communitySection
                    subscriptionSection
                    syncSection
                    feedbackSection
                }
                accountStatusMessage
            }
            .padding()
        }
        .background(AppStyle.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Import older device drafts into the currently selected environment? Their original environment is unknown.", isPresented: $confirmsLegacyRecovery, titleVisibility: .visible) {
            Button("Import into this environment") { viewModel.recoverOlderDeviceDrafts() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            apiKeyDraft = aiSettingsStore.apiKey
        }
        .sheet(isPresented: $showsFeedback) {
            if let feedbackService {
                NavigationStack {
                    FeedbackView(feedbackService: feedbackService)
                }
            }
        }
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
    }

    private var accountSection: some View {
        section {
            NavigationLink {
                AccountDetailView(viewModel: viewModel, isPro: isPro)
            } label: {
                HStack(spacing: 12) {
                    LinkedInProfilePhoto(pictureURL: viewModel.profile?.pictureURL, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.profile?.name ?? "Account")
                            .font(.headline)
                            .foregroundStyle(AppStyle.ink)
                        if let connectedAt = viewModel.connectedAt {
                            Text("Registered \(connectedAt.formatted(date: .numeric, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(AppStyle.muted)
                        }
                        TokenExpiryInfo(viewModel: viewModel)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(AppStyle.muted)
                }
                .padding()
                .background(AppStyle.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppStyle.ink.opacity(0.16), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var communitySection: some View {
        section {
            communityLink
        }
    }

    private var syncSection: some View {
        section {
            Group {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Reduce data usage", isOn: $syncSettingsStore.isDataReductionEnabled)
                        .font(.headline)
                        .foregroundStyle(AppStyle.ink)
                        .onChange(of: syncSettingsStore.isDataReductionEnabled) { _, _ in
                            syncSettingsStore.save()
                        }

                    Text("When on, automatic draft sync is paused. Scheduling still uploads the selected draft and its image so Bloomary can publish it.")
                        .font(.caption)
                        .foregroundStyle(AppStyle.muted)

                    Button(viewModel.isExportingDrafts ? "Exporting..." : "Export all drafts") {
                        viewModel.exportDrafts()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(viewModel.isExportingDrafts)
                    if let url = viewModel.exportedDraftsURL {
                        ShareLink(item: url) {
                            Label("Share export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .padding()
                .background(AppStyle.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var subscriptionSection: some View {
        section {
            Text(viewModel.planStatus)
                .font(.subheadline)
                .foregroundStyle(AppStyle.ink)
            if !isPro {
                Button {
                    onShowPurchase()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Bloomary Pro", systemImage: "star.fill")
                            .font(.headline)
                            .foregroundStyle(AppStyle.ink)
                        Text("Full access — publish, schedule, and edit up to 50 drafts.")
                            .font(.subheadline)
                            .foregroundStyle(AppStyle.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(AppStyle.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppStyle.coral.opacity(0.4), lineWidth: 1)
                    }
                }
            }
        }
    }

    private var aiSection: some View {
        section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Gemini API key")
                    .font(.headline)
                    .foregroundStyle(AppStyle.ink)

                if aiSettingsStore.apiKey.isEmpty || isEditingAPIKey {
                    SecureField("Gemini API key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                } else {
                    HStack {
                        Text("••••••••")
                            .font(.body.monospaced())
                            .foregroundStyle(AppStyle.ink)
                        Spacer()
                        Button("Change") {
                            isEditingAPIKey = true
                            apiKeyDraft = ""
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppStyle.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button("Save AI settings") {
                    aiSettingsStore.apiKey = apiKeyDraft
                    aiSettingsStore.save()
                    isEditingAPIKey = false
                }
                .buttonStyle(SecondaryButtonStyle())

                if !aiSettingsStore.apiKey.isEmpty {
                    Button("Clear Gemini key", role: .destructive) {
                        if aiSettingsStore.clearAPIKey() {
                            apiKeyDraft = ""
                            isEditingAPIKey = false
                        }
                    }
                }

                Picker("Post language", selection: $aiSettingsStore.postLanguage) {
                    ForEach(PostLanguage.all, id: \.self) { Text(PostLanguage.label($0)).tag($0) }
                }
                .pickerStyle(.menu)

                Text("Write in any language. AI returns the post in the language you choose.")
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)

                Text("Use a Gemini key that Google accepts for Gemini API. Free quota, billing, region, and key restrictions are handled by Google.")
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)

                if let message = aiSettingsStore.statusMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppStyle.muted)
                }
            }
            .padding()
            .background(AppStyle.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if hasFeedback {
            section {
                feedbackButton
            }
        }
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
    }

    private var connectButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(viewModel.isConnecting ? "Connecting..." : "Connect LinkedIn") {
                viewModel.connect()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isConnecting)

            Text("Connect LinkedIn to export your drafts.")
                .font(.caption)
                .foregroundStyle(AppStyle.muted)

            Button("Demo") {
                demoCodeDraft = ""
                showsDemoCodeAlert = true
            }
            .font(.caption)
            .foregroundStyle(AppStyle.muted)

            VStack(alignment: .leading, spacing: 4) {
                Text("By logging in, you accept Bloomary's")
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)
                HStack(spacing: 4) {
                    Link("Privacy Policy", destination: URL(string: "https://bloomary.life/privacy/")!)
                        .foregroundStyle(AppStyle.coral)
                    Text("and")
                        .foregroundStyle(AppStyle.muted)
                    Link("Terms and Conditions", destination: URL(string: "https://bloomary.life/terms/")!)
                        .foregroundStyle(AppStyle.coral)
                    Text(".")
                        .foregroundStyle(AppStyle.muted)
                }
                .font(.caption)
            }
        }
        .alert("Demo code", isPresented: $showsDemoCodeAlert) {
            TextField("Code", text: $demoCodeDraft)
            Button("Enter") {
                let code = demoCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { return }
                viewModel.setDemoSession(code: code)
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var communityLink: some View {
        Link(destination: URL(string: "https://t.me/+NDQcpuABme9iYTU0")!) {
            rowLabel("Community", systemImage: "person.2")
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(AppStyle.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppStyle.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppStyle.ink.opacity(0.16), lineWidth: 1)
            }
    }

    private var feedbackButton: some View {
        Button {
            showsFeedback = true
            AppTelemetry.track(.feedbackOpened)
        } label: {
            Label("Send feedback", systemImage: "ladybug")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppStyle.coral)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var accountStatusMessage: some View {
        if let message = viewModel.statusMessage {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppStyle.muted)
        }
    }

}

/// Shows whether the LinkedIn token is expired or when it expires next.
private struct TokenExpiryInfo: View {
    @ObservedObject var viewModel: AccountViewModel

    var body: some View {
        Group {
            if viewModel.isTokenExpired {
                Text("LinkedIn token expired")
                    .font(.caption)
                    .foregroundStyle(AppStyle.coral)
            } else if let expiresAt = viewModel.tokenExpiresAt {
                Text("Expires \(expiresAt.formatted(date: .numeric, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)
            }
        }
    }
}

private struct AccountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsLegacyRecovery = false
    @ObservedObject var viewModel: AccountViewModel
    let isPro: Bool
    @State private var showsDeleteConfirmation = false
    @State private var deletionReason = ""
    @State private var showsEnvironmentToggle = false
    @State private var showsRestartAlert = false
    @State private var showsManageSubscriptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Account")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppStyle.ink)

                accountCard
                accountStatusMessage
            }
            .padding()
        }
        .background(AppStyle.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                versionFooter
                if viewModel.isConnected {
                    Button("Delete account", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding()
        }
        .overlay {
            if showsDeleteConfirmation {
                deleteConfirmationModal
            }
        }
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if !isConnected {
                dismiss()
            }
        }
        .confirmationDialog("Backend environment", isPresented: $showsEnvironmentToggle, titleVisibility: .visible) {
            ForEach(BackendEnvironment.allCases, id: \.self) { environment in
                Button(environment.displayName) {
                    guard environment != BackendEnvironment.selected else { return }
                    BackendEnvironment.selected = environment
                    showsRestartAlert = true
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Selected: \(BackendEnvironment.selected.displayName)")
        }
        .alert("Restart required", isPresented: $showsRestartAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Restart the app to switch to \(BackendEnvironment.selected.displayName).")
        }
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let profile = viewModel.profile {
                HStack(alignment: .top, spacing: 12) {
                    LinkedInProfilePhoto(pictureURL: profile.pictureURL, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                        if let headline = profile.displayHeadline {
                            Text(headline)
                                .font(.subheadline)
                                .foregroundStyle(AppStyle.muted)
                        }
                        Text("Registered \(viewModel.connectedAt?.formatted(date: .numeric, time: .omitted) ?? "")")
                            .font(.caption)
                            .foregroundStyle(AppStyle.muted)
                        TokenExpiryInfo(viewModel: viewModel)
                    }
                }

                Button(viewModel.isLoggingOut ? "Logging out..." : "Log out") {
                    viewModel.logOut()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(viewModel.isLoggingOut)
                .padding(.top, 8)

                if isPro, viewModel.subscriptionSource != "apple" {
                    Text("Your subscription is managed on the web.")
                    Link("Manage subscription on web", destination: URL(string: "https://platform.bloomary.life/settings")!)
                } else if isPro {
                    Button("Manage Subscriptions") {
                        showsManageSubscriptions = true
                    }
                    .font(.headline)
                    .foregroundStyle(AppStyle.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppStyle.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppStyle.ink.opacity(0.16), lineWidth: 1)
                    }
                }
            } else {
                Text("Not connected.")
                    .foregroundStyle(AppStyle.muted)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var accountStatusMessage: some View {
        if let message = viewModel.statusMessage {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppStyle.muted)
        }
    }

    private var deleteConfirmationModal: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Delete account?")
                        .font(.headline)
                        .foregroundStyle(AppStyle.ink)
                    Text("This deletes your LinkedIn connection, drafts, saved Gemini key, account settings, and local authorization token. Support, legal, and security records may be retained where required.")
                        .font(.subheadline)
                        .foregroundStyle(AppStyle.muted)
                    if isPro {
                        Text("Deleting your account does not cancel your subscription. It may continue renewing. Manage cancellation separately, or choose to delete the account anyway.")
                        if viewModel.subscriptionSource == "apple" {
                            Button("Manage in App Store") {
                                showsDeleteConfirmation = false
                                showsManageSubscriptions = true
                            }
                        } else {
                            Link("Manage subscription on web", destination: URL(string: "https://platform.bloomary.life/settings")!)
                        }
                    }
                    TextField("Reason (optional)", text: $deletionReason)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.sentences)

                    VStack(spacing: 10) {
                        Button("Cancel") {
                            showsDeleteConfirmation = false
                            deletionReason = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)

                        Button("Delete account", role: .destructive) {
                            showsDeleteConfirmation = false
                            viewModel.deleteAccount { dismiss() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(width: proxy.size.width * 0.7)
                .background(AppStyle.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: AppStyle.ink.opacity(0.18), radius: 18, x: 0, y: 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var versionFooter: some View {
        VStack(spacing: 2) {
            Text(appVersion)
                .font(.caption2)
                .foregroundStyle(AppStyle.muted)
            if BackendEnvironment.selected != .production {
                Text(BackendEnvironment.selected.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppStyle.coral)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 5) {
            showsEnvironmentToggle = true
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
