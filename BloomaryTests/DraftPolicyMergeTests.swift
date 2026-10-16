import Foundation
import Testing
@testable import Bloomary

struct DraftPolicyMergeTests {
    @Test
    func mergeKeepsNewestDraft() {
        let draftID = UUID()
        let local = Draft(id: draftID, body: "local", updatedAt: Date(timeIntervalSince1970: 20))
        let remote = Draft(id: draftID, body: "remote", updatedAt: Date(timeIntervalSince1970: 10))

        let merged = DraftPolicy.merge(local: [local], remote: [remote], maxDrafts: 15)

        #expect(merged == [local])
    }

    @Test
    func mergePreservesLocalImageDataWhenRemoteIsNewer() {
        let draftID = UUID()
        let imageData = Data([1, 2, 3])
        let local = Draft(
            id: draftID,
            body: "local",
            imageData: imageData,
            imageFilename: "image.jpg",
            imageMimeType: "image/jpeg",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let remote = Draft(id: draftID, body: "remote", updatedAt: Date(timeIntervalSince1970: 20))

        let merged = DraftPolicy.merge(local: [local], remote: [remote], maxDrafts: 15)

        #expect(merged.first?.body == "remote")
        #expect(merged.first?.imageData == imageData)
        #expect(merged.first?.imageFilename == "image.jpg")
        #expect(merged.first?.imageMimeType == "image/jpeg")
    }
}
