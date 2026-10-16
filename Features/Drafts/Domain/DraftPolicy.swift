import Foundation

/// Pure draft list policies: save (create/update), pruning to the max draft
/// count, and deletion. No SwiftUI, URLSession, UserDefaults, Keychain, or
/// MainActor — unit-testable in isolation.
enum DraftPolicy {
    struct SaveResult: Equatable {
        let drafts: [Draft]
        let editingDraftID: Draft.ID?
        /// Non-nil when a draft was created or its content actually changed.
        let changedDraft: Draft?
        let limitReached: Bool
    }

    static func trimmedBody(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies an editor save: updates the edited draft in place when content
    /// changed, or creates a new draft at the top of the list. The result is
    /// pruned to `maxDrafts`. Creating a new draft is blocked when at the limit.
    static func save(
        drafts: [Draft],
        editingDraftID: Draft.ID?,
        body: String,
        maxDrafts: Int,
        imageData: Data? = nil,
        imageFilename: String? = nil,
        imageMimeType: String? = nil,
        now: Date = Date()
    ) -> SaveResult {
        if let editingDraftID, let index = drafts.firstIndex(where: { $0.id == editingDraftID }) {
            var drafts = drafts
            guard drafts[index].body != body ||
                    drafts[index].imageData != imageData ||
                    drafts[index].imageFilename != imageFilename ||
                    drafts[index].imageMimeType != imageMimeType else {
                return SaveResult(drafts: drafts, editingDraftID: editingDraftID, changedDraft: nil, limitReached: false)
            }
            drafts[index].body = body
            if drafts[index].imageData != imageData { drafts[index].remoteImage = nil }
            drafts[index].imageData = imageData
            drafts[index].imageFilename = imageFilename
            drafts[index].imageMimeType = imageMimeType
            drafts[index].updatedAt = now
            let edited = drafts.remove(at: index)
            drafts.insert(edited, at: 0)
            return SaveResult(drafts: drafts, editingDraftID: editingDraftID, changedDraft: edited, limitReached: false)
        }
        if drafts.count >= maxDrafts {
            return SaveResult(drafts: drafts, editingDraftID: editingDraftID, changedDraft: nil, limitReached: true)
        }
        let draft = Draft(
            body: body,
            imageData: imageData,
            imageFilename: imageFilename,
            imageMimeType: imageMimeType,
            createdAt: now,
            updatedAt: now
        )
        return SaveResult(drafts: [draft] + drafts, editingDraftID: draft.id, changedDraft: draft, limitReached: false)
    }

    static func prune(_ drafts: [Draft], maxDrafts: Int) -> [Draft] {
        Array(drafts.prefix(maxDrafts))
    }

    static func delete(_ drafts: [Draft], id: Draft.ID) -> [Draft] {
        drafts.filter { $0.id != id }
    }

    /// Merges two draft lists by ID, keeping the newest `updatedAt` per draft
    /// and preserving local image data when the newer entry has none. Used to
    /// migrate signed-out drafts into the signed-in account on first login.
    static func merge(local: [Draft], remote: [Draft], maxDrafts: Int) -> [Draft] {
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for draft in remote {
            if let existing = byID[draft.id], existing.updatedAt >= draft.updatedAt {
                continue
            }
            var merged = draft
            if let existing = byID[draft.id], merged.imageData == nil {
                merged.imageData = existing.imageData
                merged.imageFilename = existing.imageFilename
                merged.imageMimeType = existing.imageMimeType
            }
            byID[draft.id] = merged
        }
        // Soft enforcement: keep all drafts regardless of limit.
        // Limit is enforced on new draft creation (DraftPolicy.save), not on sync/merge.
        return Array(byID.values)
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
