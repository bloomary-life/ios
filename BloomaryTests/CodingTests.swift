import Foundation
import Testing
@testable import Bloomary

struct CodingTests {
    private struct Timestamp: Codable {
        let date: Date
    }

    @Test
    func submillisecondTimestampsRetainTheirOrderThroughCoding() throws {
        let first = Timestamp(date: Date(timeIntervalSince1970: 1_791_712_810.123456))
        let second = Timestamp(date: first.date.addingTimeInterval(0.0001))
        let decoded = try [first, second].map {
            try JSONDecoder.app.decode(Timestamp.self, from: JSONEncoder.app.encode($0))
        }

        #expect(decoded[0].date < decoded[1].date)
        #expect(abs(decoded[0].date.timeIntervalSince(first.date)) < 0.000001)
        #expect(abs(decoded[1].date.timeIntervalSince(second.date)) < 0.000001)
    }

    @Test
    func legacyWholeSecondTimestampsStillDecode() throws {
        let data = Data(#"{"date":"1970-01-01T00:00:10Z"}"#.utf8)
        let decoded = try JSONDecoder.app.decode(Timestamp.self, from: data)
        #expect(decoded.date == Date(timeIntervalSince1970: 10))
    }

    @Test
    func draftCacheRetainsSubmillisecondEditTime() throws {
        let name = "CodingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = UserDefaultsDraftRepository(key: "drafts", defaults: defaults)
        let updatedAt = Date(timeIntervalSince1970: 1_791_712_810.123456)
        let draft = Draft(id: UUID(), body: "Newer edit", createdAt: updatedAt, updatedAt: updatedAt)
        let snapshot = DraftSnapshot(drafts: [draft], ownerID: "member-1")
        defaults.set(try JSONEncoder.app.encode(snapshot), forKey: "drafts.member-1")

        let loaded = repository.loadDrafts(ownerID: "member-1")
        #expect(loaded.count == 1)
        #expect(loaded.first.map { abs($0.updatedAt.timeIntervalSince(updatedAt)) < 0.000001 } == true)
    }
}
