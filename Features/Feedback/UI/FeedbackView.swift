import PhotosUI
import ImageIO
import UIKit
import SwiftUI

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var linkedInSessionStore: LinkedInSessionStore
    @State private var title = ""
    @State private var message = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var attachments: [FeedbackImageAttachment] = []
    @State private var isSending = false
    @State private var isLoadingAttachments = false
    @State private var attachmentLoadTask: Task<Void, Never>?
    @State private var attachmentGeneration = UUID()
    @State private var statusMessage = ""

    let feedbackService: FeedbackService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                form
                links
            }
            .padding()
        }
        .background(AppStyle.paper)
        .navigationTitle("Feedback")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .onChange(of: selectedItems) { _, newItems in
            loadAttachments(from: newItems)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome")
                .font(.title2)
                .fontWeight(.semibold)
            Text("We're open to your thoughts to make this app bring you more, so don't hesitate to share your ideas, feedback on app work, or whatever you may find insightful.")
                .foregroundStyle(AppStyle.muted)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $message)
                .frame(minHeight: 180)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppStyle.ink.opacity(0.12), lineWidth: 1)
                )

            PhotosPicker(selection: $selectedItems, maxSelectionCount: 5, matching: .images) {
                Label("Attach images", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(SecondaryButtonStyle())

            if !attachments.isEmpty {
                Text("\(attachments.count) image\(attachments.count == 1 ? "" : "s") attached")
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(AppStyle.muted)
            }

            Button(isSending ? "Sending..." : "Send feedback") {
                sendFeedback()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSending || isLoadingAttachments || attachments.count != selectedItems.count || linkedInSessionStore.postCredential == nil)
            if linkedInSessionStore.postCredential == nil {
                Text("Connect LinkedIn to send feedback in the app, or use the support form.")
                Link("Support form", destination: URL(string: "https://bloomary.life/support/")!)
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link("Privacy policy", destination: URL(string: "https://bloomary.life/privacy/")!)
        }
        .font(.subheadline)
        .foregroundStyle(Color.black)
    }

    private func loadAttachments(from items: [PhotosPickerItem]) {
        attachmentLoadTask?.cancel()
        let generation = UUID()
        attachmentGeneration = generation
        isLoadingAttachments = true
        attachments = []
        attachmentLoadTask = Task {
            defer { if attachmentGeneration == generation { isLoadingAttachments = false } }
            var loaded: [FeedbackImageAttachment] = []
            do {
                for (index, item) in items.enumerated() {
                    guard let original = try await item.loadTransferable(type: Data.self) else {
                        throw FeedbackError.server("A selected photo could not be loaded. Select it again.")
                    }
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
                              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 1600
                              ] as CFDictionary),
                              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8) else {
                            throw FeedbackError.server("A selected photo could not be decoded.")
                        }
                        return FeedbackImageAttachment(filename: "feedback-\(index + 1).jpg", content: jpeg.base64EncodedString())
                    }.value
                    loaded.append(attachment)
                    guard loaded.reduce(0, { $0 + $1.content.utf8.count }) <= 8 * 1024 * 1024 else {
                        throw FeedbackError.server("Images are too large. Attach fewer photos.")
                    }
                }
                guard !Task.isCancelled, attachmentGeneration == generation else { return }
                attachments = loaded
                statusMessage = ""
            } catch {
                guard !Task.isCancelled, attachmentGeneration == generation else { return }
                attachments = []
                statusMessage = error.localizedDescription
            }
        }
    }

    private func sendFeedback() {
        guard !isSending, !isLoadingAttachments, attachments.count == selectedItems.count else { return }
        let submittedTitle = title
        let submittedMessage = message
        let submittedItems = selectedItems
        let submittedAttachments = attachments
        let credential = linkedInSessionStore.postCredential
        let identity = senderIdentity
        isSending = true
        statusMessage = ""
        Task {
            do {
                try await feedbackService.send(
                    title: submittedTitle,
                    message: submittedMessage,
                    identity: identity,
                    attachments: submittedAttachments,
                    credential: credential
                )
                await MainActor.run {
                    statusMessage = "Feedback sent."
                    isSending = false
                    AppTelemetry.track(.feedbackSent)
                    if linkedInSessionStore.postCredential == credential {
                        if title == submittedTitle { title = "" }
                        if message == submittedMessage { message = "" }
                        if selectedItems == submittedItems {
                            selectedItems = []
                            attachments = []
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private var senderIdentity: FeedbackSenderIdentity? {
        guard let profile = linkedInSessionStore.token?.profile else { return nil }
        return FeedbackSenderIdentity(name: profile.name, linkedInID: profile.memberID, email: profile.email)
    }
}
