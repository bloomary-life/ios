import Foundation

struct Draft: Identifiable, Codable, Equatable {
    let id: UUID
    var wireID: String?
    var serverID: String { wireID ?? id.uuidString.lowercased() }
    var body: String
    var imageData: Data?
    var imageFilename: String?
    var imageMimeType: String?
    var remoteImage: DraftSyncImage?
    var status: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        wireID: String? = nil,
        body: String,
        imageData: Data? = nil,
        imageFilename: String? = nil,
        imageMimeType: String? = nil,
        remoteImage: DraftSyncImage? = nil,
        status: String? = "draft",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.wireID = wireID
        self.body = body
        self.imageData = imageData
        self.imageFilename = imageFilename
        self.imageMimeType = imageMimeType
        self.remoteImage = remoteImage
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var title: String {
        body
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(72)
            .description
        ?? "Untitled draft"
    }
}
