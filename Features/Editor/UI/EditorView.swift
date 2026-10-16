import SwiftUI

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewExpanded = false
    @State private var formatCommand: EditorFormatCommand?
    @State private var scheduleDate = AppConfiguration.Scheduling.defaultScheduleDate()
    @State private var showsEmojiPicker = false
    @State private var showsImageEditor = false

    let onShowDrafts: () -> Void
    let onPostSucceeded: () -> Void
    let onShowPurchase: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button {
                        onShowDrafts()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(AppStyle.ink)
                    .accessibilityLabel("Back to drafts")

                    Text("Write your post")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppStyle.ink)
                }

                if let warning = viewModel.draftLimitWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppStyle.coral)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(AppStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(10)
                    .background(AppStyle.coral.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(spacing: 0) {
                    editorToolbar
                    HStack {
                        Text(viewModel.syncStatus.message)
                            .font(.caption)
                            .foregroundStyle(AppStyle.muted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    ZStack(alignment: .topTrailing) {
                        if viewModel.editorText.isEmpty {
                            Text("Write a LinkedIn post...")
                                .foregroundStyle(AppStyle.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 17)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        RichTextEditor(text: $viewModel.editorText, command: $formatCommand) {
                            AppTelemetry.track(.editorStarted)
                        }
                            .frame(minHeight: 260)
                            .padding(12)
                            .padding(.trailing, 36)

                        Button {
                            viewModel.clearEditor()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                        }
                        .foregroundStyle(AppStyle.ink)
                        .accessibilityLabel("Clear post text")
                        .disabled(!viewModel.hasEditorText && viewModel.attachedImage == nil)
                        .opacity(viewModel.hasEditorText ? 1 : 0)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                    }
                }
                    .frame(maxWidth: .infinity)
                    .background(AppStyle.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                editorStatusMessage
                Text(postingSuggestions)
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)
                preview
                attachedImagePreview
            }
            .padding()
        }
        .background(AppStyle.paper)
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .alert("Check LinkedIn before posting again", isPresented: $viewModel.showsPublishRetryConfirmation) {
            Button("Open LinkedIn") { openLinkedInProfilePosts() }
            Button("I checked · Post again", role: .destructive) { viewModel.publish(confirmRetry: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This content was already submitted. It may have published even if Bloomary did not receive a response.")
        }
        .sheet(isPresented: $viewModel.showsPostSuccess, onDismiss: onPostSucceeded) {
            PostSuccessView(
                onViewOnLinkedIn: { openLinkedInProfilePosts() }
            )
        }
        .sheet(isPresented: $showsEmojiPicker) {
            EmojiPickerView { emoji in
                formatCommand = .insert(emoji)
                showsEmojiPicker = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $viewModel.showsSchedulePicker) {
            NavigationStack {
                Form {
                    DatePicker("Date and time", selection: $scheduleDate, in: Date().addingTimeInterval(AppConfiguration.Scheduling.minimumLeadTime)...viewModel.maximumScheduleDate)
                        .datePickerStyle(.compact)
                    Text(viewModel.scheduleLimitText)
                        .font(.caption)
                        .foregroundStyle(AppStyle.muted)
                    if let message = viewModel.scheduleMessage {
                        Text(message).font(.callout).foregroundStyle(AppStyle.coral)
                    }
                }
                .navigationTitle("Schedule post")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { viewModel.showsSchedulePicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(viewModel.isScheduling ? "Scheduling…" : "Schedule") { viewModel.schedule(at: scheduleDate) }
                            .disabled(viewModel.isScheduling)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showsImageEditor) {
            PostImageEditorView(initialImage: viewModel.attachedImage, maxImageBytes: viewModel.maxImageBytes) { attachment in
                viewModel.setAttachedImage(attachment)
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            // Gate on lapsed, not isPro: trial schedules too. Locked controls
            // stay tappable and open the plan sheet instead of going inert.
            Button(viewModel.isLapsed ? "Schedule · Pro" : "Schedule") {
                if viewModel.isLapsed {
                    viewModel.showPlanRequired()
                    onShowPurchase()
                } else {
                    scheduleDate = AppConfiguration.Scheduling.defaultScheduleDate()
                    viewModel.scheduleMessage = nil
                    viewModel.showsSchedulePicker = true
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(viewModel.isPosting || viewModel.isScheduling || (!viewModel.hasEditorText && viewModel.attachedImage == nil))

            Button("Save draft") {
                if viewModel.save() {
                    onShowDrafts()
                } else if viewModel.isLapsed {
                    onShowPurchase()
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(SecondaryButtonStyle())
            .disabled(viewModel.isDraftLimitReached && !viewModel.isEditingExistingDraft && !viewModel.isLapsed)

            Button(viewModel.isPosting ? "Posting..." : "Post to LinkedIn") {
                if viewModel.isLapsed {
                    viewModel.showPlanRequired()
                    onShowPurchase()
                } else {
                    viewModel.publish()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.isPosting || viewModel.isNaturalizing)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(AppStyle.paper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppStyle.ink.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var postingSuggestions: String {
        let times = AppConfiguration.Scheduling.weekdayPostTimes
        let day = Calendar.current.component(.weekday, from: Date()) - 1
        return "Posting suggestions · Today: \(times[day]) · Tomorrow: \(times[(day + 1) % 7]). Fixed weekday suggestions in your local time; not personalized analytics."
    }

    private var editorToolbar: some View {
        VStack(spacing: 0) {
            Button("Copy post", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = viewModel.editorText
            }
            .disabled(!viewModel.hasEditorText)
            .accessibilityLabel("Copy whole post")
            // Row 1: text formatting
            HStack {
                formatButton("B", "Bold", .bold).fontWeight(.bold)
                Spacer()
                formatButton("I", "Italic", .italic).italic()
                Spacer()
                formatButton("S", "Strikethrough", .strikethrough).strikethrough()
                Spacer()
                formatButton("U", "Underline", .underline).underline()
                Spacer()
                formatButton("<>", "Code", .code)
                Spacer()
                formatButton("T/", "Clear formatting", .clear)
            }
            // Row 2: actions and lists
            HStack {
                toolbarIconButton("wand.and.stars", viewModel.isNaturalizing ? "Naturalizing English" : "Naturalize English") {
                    viewModel.naturalizeEnglish()
                }
                .disabled(!viewModel.hasEditorText || viewModel.isNaturalizing || viewModel.isPosting)
                Spacer()
                toolbarIconButton("face.smiling", "Insert emoji") {
                    showsEmojiPicker = true
                }
                Spacer()
                toolbarIconButton("photo.on.rectangle.angled", "Open image editor") {
                    showsImageEditor = true
                }
                Spacer()
                formatImageButton("list.bullet", "Bullet list", .bullets)
                Spacer()
                formatImageButton("list.number", "Numbered list", .numbered)
            }
        }
        .padding(.horizontal, 8)
        .background(AppStyle.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppStyle.ink.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func formatButton(_ title: String, _ label: String, _ command: EditorFormatCommand) -> some View {
        Button(title) {
            formatCommand = command
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(AppStyle.ink.opacity(0.72))
        .frame(width: 44, height: 44)
        .accessibilityLabel(label)
        .help(label)
    }

    private func formatImageButton(_ systemName: String, _ label: String, _ command: EditorFormatCommand) -> some View {
        Button {
            formatCommand = command
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
        }
        .foregroundStyle(AppStyle.ink.opacity(0.72))
        .frame(width: 44, height: 44)
        .accessibilityLabel(label)
        .help(label)
    }

    private func toolbarIconButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
        }
        .foregroundStyle(AppStyle.ink.opacity(0.72))
        .frame(width: 44, height: 44)
        .accessibilityLabel(label)
        .help(label)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewHeader

            VStack(alignment: .leading, spacing: 0) {
                Text(previewExpanded ? viewModel.previewText : String(viewModel.previewText.prefix(210)))
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if viewModel.previewText.count > 210 {
                    Button(previewExpanded ? "Show less" : "…more") { previewExpanded.toggle() }
                        .foregroundStyle(colorScheme == .dark ? Color.gray : Color.secondary)
                }
                if let image = viewModel.attachedImage {
                    Image(uiImage: image).resizable().scaledToFit().padding(.top, 12)
                }
            }
        }
        .padding()
        .frame(maxWidth: 390)
        .background(colorScheme == .dark ? Color(white: 0.12) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppStyle.ink.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var attachedImagePreview: some View {
        if let image = viewModel.attachedImage {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    viewModel.removeAttachedImage()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .foregroundStyle(AppStyle.ink)
                .accessibilityLabel("Remove image")
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var editorStatusMessage: some View {
        if let message = viewModel.scheduleMessage ?? viewModel.statusMessage {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(viewModel.scheduleStatus == "published" ? .green : AppStyle.muted)
        }
    }


    @ViewBuilder
    private var previewHeader: some View {
        if let profile = viewModel.profile {
            HStack(spacing: 10) {
                LinkedInProfilePhoto(pictureURL: profile.pictureURL, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                    Text(profile.displayHeadline ?? "Now")
                        .font(.subheadline)
                        .foregroundStyle((colorScheme == .dark ? Color.gray : AppStyle.muted))
                }
            }
        } else {
            Text("Connect LinkedIn to preview your profile.")
                .font(.subheadline)
                .foregroundStyle((colorScheme == .dark ? Color.gray : AppStyle.muted))
        }
    }

    private func openLinkedInProfilePosts() {
        guard let url = URL(string: "https://www.linkedin.com/in/me/recent-activity/all/") else { return }
        UIApplication.shared.open(url)
    }
}

private struct EmojiPickerView: View {
    private let emojis = [
        "😀", "😄", "😊", "🙂", "😉", "😍", "🥳", "🔥",
        "✨", "💡", "✅", "🚀", "📌", "📈", "💬", "👏",
        "🙏", "🤝", "🎯", "⭐", "❤️", "💙", "🧠", "✍️",
        "👀", "🙌", "⚡️", "🏆", "💪", "🌱", "🔔", "🧩"
    ]

    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onSelect(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert \(emoji)")
                    }
                }
            }
            .background(AppStyle.paper)
            .navigationTitle("Emoji")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
