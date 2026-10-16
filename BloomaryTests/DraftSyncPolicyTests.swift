import Foundation
import Testing
@testable import Bloomary

struct DraftSyncPolicyTests {
    @Test
    func enqueueCoalescesByOwnerAndDraft() {
        let draftID = UUID()
        let older = DraftSyncMutation(ownerID: "member-1", operation: .upsert, draftID: draftID, draft: Draft(id: draftID, body: "old"))
        let newer = DraftSyncMutation(ownerID: "member-1", operation: .delete, draftID: draftID)

        let queue = DraftSyncPolicy.enqueue(newer, into: [older])

        #expect(queue == [newer])
    }

    @Test
    func mergeKeepsNewestDraftAndAppliesRemoteImageRemoval() {
        let draftID = UUID()
        let local = Draft(
            id: draftID,
            body: "local",
            imageData: Data([1, 2, 3]),
            imageFilename: "local.jpg",
            imageMimeType: "image/jpeg",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let remote = Draft(id: draftID, body: "remote", updatedAt: Date(timeIntervalSince1970: 20))

        let merged = DraftSyncPolicy.merge(local: [local], remote: [remote], maxDrafts: 15)

        #expect(merged.first?.body == "remote")
        #expect(merged.first?.imageData == nil)
        #expect(merged.first?.imageFilename == nil)
    }

    @Test
    func failedMutationGetsRetryDelay() {
        let mutation = DraftSyncMutation(ownerID: "member-1", operation: .delete, draftID: UUID())
        let failed = DraftSyncPolicy.markFailed(mutation, error: TestError.offline, now: Date(timeIntervalSince1970: 0), jitter: 0)

        #expect(failed.attemptCount == 1)
        #expect(failed.nextAttemptAt == Date(timeIntervalSince1970: 30))
        #expect(failed.lastError == "offline")
    }

    @Test
    func mutationIsParkedAfterRetryWindowAndRearmedOnNextLaunch() {
        var mutation = DraftSyncMutation(ownerID: "member-1", operation: .upsert, draftID: UUID())
        mutation.attemptCount = DraftSyncPolicy.maxRetryAttempts - 1
        let parked = DraftSyncPolicy.markFailed(mutation, error: TestError.offline, now: Date(timeIntervalSince1970: 0), jitter: 0)

        let rearmed = DraftSyncPolicy.resetParked(in: [parked])

        #expect(DraftSyncPolicy.isParked(parked))
        #expect(rearmed[0].attemptCount == 0)
        #expect(rearmed[0].nextAttemptAt == nil)
        #expect(DraftSyncPolicy.dueMutations(from: rearmed).count == 1)
    }

}

private enum TestError: LocalizedError {
    case offline

    var errorDescription: String? { "offline" }
}
