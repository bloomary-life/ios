import CryptoKit
import Foundation
import OSLog

protocol DraftSyncing: Sendable {
    func listDrafts(memberID: String, accessToken: String) async throws -> [Draft]
    func upsertDraft(_ draft: Draft, memberID: String, accessToken: String) async throws -> Draft
    func deleteDraft(id: Draft.ID, memberID: String, accessToken: String) async throws
    func deleteDraft(_ draft: Draft, memberID: String, accessToken: String) async throws
}

extension DraftSyncing {
    func deleteDraft(_ draft: Draft, memberID: String, accessToken: String) async throws {
        try await deleteDraft(id: draft.id, memberID: memberID, accessToken: accessToken)
    }
}

// Configuration is immutable; URLSession and NSCache synchronize their mutable state.
final class SyncedDraftsService: DraftSyncing, @unchecked Sendable {
    private let apiBaseURL: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "com.dailymind.bloomary", category: "DraftImages")
    private let imageCache = NSCache<NSString, NSData>()

    init(apiBaseURL: URL, session: URLSession = .shared) {
        self.apiBaseURL = apiBaseURL
        self.session = session
    }

    func listDrafts(memberID: String, accessToken: String) async throws -> [Draft] {
        let response = try await sync(memberID: memberID, accessToken: accessToken)
        return try await response.drafts.asyncCompactMap { try await draft(from: $0) }
    }

    func upsertDraft(_ draft: Draft, memberID: String, accessToken: String) async throws -> Draft {
        let upsert = try await draftSyncUpsert(draft, memberID: memberID, accessToken: accessToken)
        let response = try await sync(
            upserts: [upsert],
            memberID: memberID,
            accessToken: accessToken
        )
        guard let synced = response.drafts.first(where: { $0.draftId.lowercased() == draft.serverID.lowercased() }) else {
            return draft
        }
        return try await self.draft(from: synced) ?? draft
    }

    func deleteDraft(id: Draft.ID, memberID: String, accessToken: String) async throws {
        _ = try await sync(deletes: [id.uuidString], memberID: memberID, accessToken: accessToken)
    }

    func deleteDraft(_ draft: Draft, memberID: String, accessToken: String) async throws {
        _ = try await sync(deletes: [draft.serverID], memberID: memberID, accessToken: accessToken)
    }

    private func sync(
        upserts: [DraftSyncUpsert] = [],
        deletes: [String] = [],
        memberID: String,
        accessToken: String
    ) async throws -> DraftsResponse {
        var request = authorizedRequest(path: "/api/drafts/sync", memberID: memberID, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.app.encode(DraftSyncRequest(upserts: upserts, deletes: deletes))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.app.decode(DraftsResponse.self, from: data)
    }

    private func draftSyncUpsert(_ draft: Draft, memberID: String, accessToken: String) async throws -> DraftSyncUpsert {
        guard let imageData = draft.imageData else {
            return DraftSyncUpsert(draftId: draft.serverID, body: draft.body, updatedAt: draft.updatedAt, removeImage: draft.remoteImage == nil)
        }
        let mimeType = draft.imageMimeType ?? "image/jpeg"
        let sizeBytes = Int64(imageData.count)
        let checksum = sha256Hex(imageData)
        if let image = draft.remoteImage, image.checksumSHA256 == checksum {
            return DraftSyncUpsert(draftId: draft.serverID, body: draft.body, updatedAt: draft.updatedAt)
        }
        let presign = try await presignUpload(
            draftID: draft.serverID,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            checksumSHA256: checksum,
            memberID: memberID,
            accessToken: accessToken
        )
        try await uploadImageData(imageData, presign: presign)
        let cacheKey = "\(presign.imageId):\(checksum)" as NSString
        imageCache.setObject(imageData as NSData, forKey: cacheKey, cost: imageData.count)
        return DraftSyncUpsert(
            draftId: draft.serverID,
            body: draft.body,
            updatedAt: draft.updatedAt,
            image: DraftSyncImage(
                imageId: presign.imageId,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                checksumSHA256: checksum
            )
        )
    }

    private func presignUpload(
        draftID: String,
        mimeType: String,
        sizeBytes: Int64,
        checksumSHA256: String,
        memberID: String,
        accessToken: String
    ) async throws -> DraftImagePresignUploadResponse {
        var request = authorizedRequest(path: "/api/draft-images/presign-upload", memberID: memberID, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.app.encode(
            DraftImagePresignUploadRequest(
                draftId: draftID,
                mimeType: mimeType,
                sizeBytes: sizeBytes,
                checksumSHA256: checksumSHA256
            )
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder.app.decode(DraftImagePresignUploadResponse.self, from: data)
    }

    private func uploadImageData(_ data: Data, presign: DraftImagePresignUploadResponse) async throws {
        guard let url = URL(string: presign.uploadUrl) else {
            throw SyncedDraftsError.server("Draft image upload URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in presign.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        try validateUpload(response: response, data: responseData)
    }

    private func draft(from synced: SyncedDraft) async throws -> Draft? {
        guard let uuid = UUID(uuidString: synced.draftId) else { return nil }
        let image: DownloadedDraftImage?
        do {
            image = try await downloadedImage(synced.image)
        } catch {
            logger.error("Attachment download failed; draft metadata retained: \(String(describing: type(of: error)), privacy: .public)")
            image = nil
        }
        return Draft(
            id: uuid,
            wireID: synced.draftId,
            body: synced.body,
            imageData: image?.data,
            imageFilename: image?.filename,
            imageMimeType: image?.mimeType,
            remoteImage: synced.image,
            status: synced.status,
            createdAt: synced.createdAt,
            updatedAt: synced.updatedAt
        )
    }

    private func downloadedImage(_ image: DraftSyncImage?) async throws -> DownloadedDraftImage? {
        guard let image, let downloadUrl = image.downloadUrl, let url = URL(string: downloadUrl) else {
            return nil
        }
        let cacheKey = "\(image.imageId):\(image.checksumSHA256)" as NSString
        let data: Data
        if let cached = imageCache.object(forKey: cacheKey) {
            data = cached as Data
        } else {
            let (download, response) = try await session.data(from: url)
            try validateUpload(response: response, data: download)
            data = download
            imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        }
        return DownloadedDraftImage(
            data: data,
            filename: "\(image.imageId).\(fileExtension(for: image.mimeType))",
            mimeType: image.mimeType
        )
    }

    private func authorizedRequest(path: String, memberID: String, accessToken: String) -> URLRequest {
        let url = apiBaseURL.appending(path: path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "memberId", value: memberID)]
        var request = URLRequest(url: components?.url ?? url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            Logger(subsystem: "com.dailymind.bloomary", category: "Network").error("HTTP \(http.statusCode) for \(http.url?.path ?? "unknown", privacy: .public)")
            if let apiError = try? JSONDecoder.app.decode(SyncedDraftsAPIError.self, from: data) {
                if [400, 413, 422].contains(http.statusCode) { throw SyncedDraftsError.validation(apiError.errorDescription ?? apiError.error) }
                throw SyncedDraftsError.server(apiError.errorDescription ?? apiError.error)
            }
            throw SyncedDraftsError.server("Draft sync failed.")
        }
    }

    private func validateUpload(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            Logger(subsystem: "com.dailymind.bloomary", category: "Network").error("HTTP \(http.statusCode) for \(http.url?.path ?? "unknown", privacy: .public)")
            if let apiError = try? JSONDecoder.app.decode(SyncedDraftsAPIError.self, from: data) {
                if [400, 413, 422].contains(http.statusCode) { throw SyncedDraftsError.validation(apiError.errorDescription ?? apiError.error) }
                throw SyncedDraftsError.server(apiError.errorDescription ?? apiError.error)
            }
            throw SyncedDraftsError.server("Draft image transfer failed.")
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/heic":
            return "heic"
        case "image/webp":
            return "webp"
        default:
            return "jpg"
        }
    }
}

enum SyncedDraftsError: LocalizedError {
    case validation(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message), .server(let message):
            return message
        }
    }
}

private struct DraftsResponse: Decodable {
    let drafts: [SyncedDraft]
}

private struct DraftSyncRequest: Encodable {
    let upserts: [DraftSyncUpsert]
    let deletes: [String]
}

private struct DraftSyncUpsert: Encodable {
    let draftId: String
    let body: String
    let updatedAt: Date
    let image: DraftSyncImage?
    let removeImage: Bool

    init(draftId: String, body: String, updatedAt: Date, image: DraftSyncImage? = nil, removeImage: Bool = false) {
        self.draftId = draftId
        self.body = body
        self.updatedAt = updatedAt
        self.image = image
        self.removeImage = removeImage
    }
}

private struct SyncedDraft: Decodable {
    let draftId: String
    let body: String
    let status: String?
    let image: DraftSyncImage?
    let createdAt: Date
    let updatedAt: Date
}

struct DraftSyncImage: Codable, Equatable {
    let imageId: String
    let downloadUrl: String?
    let mimeType: String
    let sizeBytes: Int64
    let checksumSHA256: String

    init(
        imageId: String,
        downloadUrl: String? = nil,
        mimeType: String,
        sizeBytes: Int64,
        checksumSHA256: String
    ) {
        self.imageId = imageId
        self.downloadUrl = downloadUrl
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.checksumSHA256 = checksumSHA256
    }
}

private struct DraftImagePresignUploadRequest: Encodable {
    let draftId: String
    let mimeType: String
    let sizeBytes: Int64
    let checksumSHA256: String
}

private struct DraftImagePresignUploadResponse: Decodable {
    let imageId: String
    let uploadUrl: String
    let headers: [String: String]
}

private struct DownloadedDraftImage {
    let data: Data
    let filename: String
    let mimeType: String
}

private struct SyncedDraftsAPIError: Decodable {
    let error: String
    let errorDescription: String?
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async throws -> [T] {
        var values: [T] = []
        for element in self {
            if let value = try await transform(element) {
                values.append(value)
            }
        }
        return values
    }
}
