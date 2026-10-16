import Foundation
import Testing
@testable import Bloomary

struct DraftPolicyTests {
    @Test
    func saveCreatesNewDraftAtTop() {
        let existing = Draft(body: "Existing")
        let now = Date(timeIntervalSince1970: 100)

        let result = DraftPolicy.save(drafts: [existing], editingDraftID: nil, body: "New post", maxDrafts: 5, now: now)

        #expect(result.drafts.count == 2)
        #expect(result.drafts.first?.body == "New post")
        #expect(result.drafts.first?.createdAt == now)
        #expect(result.editingDraftID == result.drafts.first?.id)
        #expect(result.changedDraft?.body == "New post")
    }

    @Test
    func saveUpdatesEditedDraftInPlace() {
        let edited = Draft(id: UUID(), body: "Old", updatedAt: Date(timeIntervalSince1970: 10))
        let other = Draft(id: UUID(), body: "Other", updatedAt: Date(timeIntervalSince1970: 20))
        let now = Date(timeIntervalSince1970: 100)

        let result = DraftPolicy.save(drafts: [other, edited], editingDraftID: edited.id, body: "Updated", maxDrafts: 5, now: now)

        #expect(result.drafts.count == 2)
        #expect(result.editingDraftID == edited.id)
        #expect(result.changedDraft?.id == edited.id)
        #expect(result.changedDraft?.body == "Updated")
        #expect(result.changedDraft?.updatedAt == now)
    }

    @Test
    func savePersistsImageData() {
        let imageData = Data([1, 2, 3])

        let result = DraftPolicy.save(
            drafts: [],
            editingDraftID: nil,
            body: "",
            maxDrafts: 5,
            imageData: imageData,
            imageFilename: "image.jpg",
            imageMimeType: "image/jpeg"
        )

        #expect(result.drafts.first?.imageData == imageData)
        #expect(result.drafts.first?.imageFilename == "image.jpg")
        #expect(result.drafts.first?.imageMimeType == "image/jpeg")
        #expect(result.changedDraft?.imageData == imageData)
    }

    @Test
    func saveWithUnchangedBodyReportsNoChange() {
        let edited = Draft(id: UUID(), body: "Same", imageData: Data([1]), updatedAt: Date(timeIntervalSince1970: 10))

        let result = DraftPolicy.save(
            drafts: [edited],
            editingDraftID: edited.id,
            body: "Same",
            maxDrafts: 5,
            imageData: Data([1]),
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(result.drafts == [edited])
        #expect(result.changedDraft == nil)
    }

    @Test
    func saveWithUnknownEditingIDCreatesNewDraft() {
        let result = DraftPolicy.save(drafts: [], editingDraftID: UUID(), body: "Fresh", maxDrafts: 5, now: Date(timeIntervalSince1970: 100))

        #expect(result.drafts.count == 1)
        #expect(result.changedDraft != nil)
        #expect(result.editingDraftID == result.drafts.first?.id)
    }

    @Test
    func saveBlocksNewDraftAtLimit() {
        let drafts = (0..<5).map { Draft(body: "Draft \($0)") }

        let result = DraftPolicy.save(drafts: drafts, editingDraftID: nil, body: "Overflow", maxDrafts: 5, now: Date(timeIntervalSince1970: 100))

        #expect(result.drafts.count == 5)
        #expect(result.changedDraft == nil)
        #expect(result.limitReached == true)
    }

    @Test
    func pruneKeepsNewestEntries() {
        let drafts = (0..<20).map { Draft(body: "Draft \($0)") }

        let pruned = DraftPolicy.prune(drafts, maxDrafts: 15)

        #expect(pruned.count == 15)
        #expect(pruned.last?.body == "Draft 14")
    }

    @Test
    func deleteRemovesOnlyMatchingDraft() {
        let target = Draft(id: UUID(), body: "Target")
        let other = Draft(id: UUID(), body: "Other")

        let remaining = DraftPolicy.delete([target, other], id: target.id)

        #expect(remaining == [other])
    }

    @Test
    func trimmedBodyRemovesWhitespace() {
        #expect(DraftPolicy.trimmedBody("  hello \n") == "hello")
    }
}
