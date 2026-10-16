import SwiftUI

struct DraftsView: View {
    @ObservedObject var viewModel: DraftsViewModel
    let onOpenDraft: () -> Void
    @State private var searchText = ""
    @State private var showsScheduledOnly = false
    @State private var reschedulingDraft: Draft?
    @State private var scheduleDate = AppConfiguration.Scheduling.defaultScheduleDate()
    @State private var scheduleError: String?
    @State private var isRescheduling = false
    @State private var reviewConfirmed = false

    private var visibleDrafts: [Draft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.drafts.filter { draft in
            (!showsScheduledOnly || viewModel.scheduledPost(for: draft) != nil) &&
            (query.isEmpty || draft.title.localizedCaseInsensitiveContains(query) || draft.body.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Drafts")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppStyle.ink)
                    Spacer()
                    Text(viewModel.draftCountText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(viewModel.isNearDraftLimit ? AppStyle.coral : AppStyle.muted)
                }

                TextField("Search drafts", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Draft filter", selection: $showsScheduledOnly) {
                    Text("All").tag(false)
                    Text("Scheduled").tag(true)
                }
                .pickerStyle(.segmented)

                Text(viewModel.syncStatus.message)
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)

                if viewModel.syncStatus == .failed {
                    Button("Retry sync") { viewModel.retrySync() }
                }

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(AppStyle.coral)
                        .transition(.opacity)
                }

                if viewModel.isOverDraftLimit {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppStyle.coral)
                        Text(viewModel.overLimitMessage)
                            .font(.caption)
                            .foregroundStyle(AppStyle.ink)
                    }
                    .padding(10)
                    .background(AppStyle.coral.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if visibleDrafts.isEmpty {
                    ContentUnavailableView(showsScheduledOnly ? "No scheduled posts" : "No drafts", systemImage: "doc.text", description: Text(showsScheduledOnly ? "Scheduled posts will appear here." : "Saved drafts will appear here."))
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleDrafts) { draft in
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    guard viewModel.open(draft) else { return }
                                    onOpenDraft()
                                } label: {
                                    draftContent(draft)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if draft.status != "published", viewModel.canEdit(draft),
                                   viewModel.scheduledPost(for: draft).map({ ["pending", "retry", "needs_review"].contains($0.status) }) ?? true {
                                    // Shown only when canEdit (trial or pro); trial schedules too, so no isPro gate.
                                    Button(viewModel.scheduledPost(for: draft) == nil ? "Schedule" : "Reschedule") {
                                        reviewConfirmed = false
                                        reschedulingDraft = draft
                                        let existing = viewModel.scheduledPost(for: draft).flatMap { ISO8601DateFormatter().date(from: $0.scheduledAt) }
                                        scheduleDate = existing.flatMap { $0 > Date().addingTimeInterval(AppConfiguration.Scheduling.minimumLeadTime + 60) ? $0 : nil } ?? AppConfiguration.Scheduling.defaultScheduleDate()
                                        scheduleError = nil
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                }

                                Button {
                                    viewModel.delete(draft)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppStyle.muted)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete draft")
                            }
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if draft.id != visibleDrafts.last?.id {
                                Divider()
                                    .padding(.horizontal)
                            }
                        }
                    }
                    .background(AppStyle.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppStyle.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                viewModel.refreshFromRemote()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .sheet(item: $reschedulingDraft) { draft in
            NavigationStack {
                Form {
                    DatePicker("Date and time", selection: $scheduleDate, in: Date().addingTimeInterval(AppConfiguration.Scheduling.minimumLeadTime)...viewModel.maximumScheduleDate)
                        .datePickerStyle(.compact)
                    if viewModel.scheduledPost(for: draft)?.status == "needs_review" {
                        Text("Check your LinkedIn posts before retrying: the previous attempt may already have published.")
                        Toggle("I checked LinkedIn; this post was not published", isOn: $reviewConfirmed)
                    }
                    if let scheduleError {
                        Text(scheduleError).font(.callout).foregroundStyle(AppStyle.coral)
                    }
                }
                .navigationTitle(viewModel.scheduledPost(for: draft) == nil ? "Schedule post" : "Reschedule post")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { reschedulingDraft = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isRescheduling ? "Saving…" : (viewModel.scheduledPost(for: draft) == nil ? "Schedule" : "Reschedule")) {
                            isRescheduling = true
                            Task {
                                do {
                                    try await viewModel.reschedule(draft, at: scheduleDate, reviewConfirmed: reviewConfirmed)
                                    reschedulingDraft = nil
                                } catch {
                                    scheduleError = error.localizedDescription
                                }
                                isRescheduling = false
                            }
                        }
                        .disabled(isRescheduling || (viewModel.scheduledPost(for: draft)?.status == "needs_review" && !reviewConfirmed))
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func draftContent(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.title)
                    .font(.headline)
                    .foregroundStyle(AppStyle.ink)
            if draft.status == "published" {
                    Text("Published")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppStyle.muted)
                }
            }
            if let schedule = viewModel.scheduledPost(for: draft), let date = ISO8601DateFormatter().date(from: schedule.scheduledAt) {
                Text("Scheduled · \(date.formatted(date: .abbreviated, time: .shortened)) · \(schedule.status)")
                    .font(.caption)
                    .foregroundStyle(AppStyle.muted)
            }
            Text(draft.body)
                .font(.subheadline)
                .foregroundStyle(AppStyle.muted)
                .lineLimit(3)
            Text(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(AppStyle.muted)
        }
        .padding(.vertical, 6)
    }

}
