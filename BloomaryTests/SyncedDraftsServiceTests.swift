import CryptoKit
import Foundation
import Testing
@testable import Bloomary

@Suite(.serialized)
struct SyncedDraftsServiceTests {
    @Test(arguments: ["abcdef12-3456-7890-abcd-ef1234567890", "ABCDEF12-3456-7890-ABCD-EF1234567890"])
    func remoteDraftIDRetainsItsCaseThroughSaveAndDelete(wireID: String) async throws {
        let apiHost = "api-wire-id.test"
        let recorder = RequestRecorder()
        MockURLProtocol.register(hosts: [apiHost]) { request in
            await recorder.record(request)
            let data = try #require(bodyData(from: request))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let upserts = try #require(payload["upserts"] as? [[String: Any]])
            let deletes = try #require(payload["deletes"] as? [String])
            if !deletes.isEmpty {
                #expect(deletes == [wireID])
                return try jsonResponse(["drafts": []])
            }
            if let upsert = upserts.first {
                #expect(upsert["draftId"] as? String == wireID)
                #expect(upsert["body"] as? String == "Edited")
            }
            return try jsonResponse(["drafts": [[
                "draftId": wireID,
                "body": upserts.first?["body"] as? String ?? "Remote",
                "createdAt": "2026-10-11T00:00:00Z",
                "updatedAt": "2026-10-11T00:00:01Z"
            ]]])
        }
        defer { MockURLProtocol.unregister(hosts: [apiHost]) }
        let service = SyncedDraftsService(apiBaseURL: URL(string: "https://\(apiHost)")!, session: mockSession())
        let drafts = try await service.listDrafts(memberID: "member-1", accessToken: "token")
        var draft = try #require(drafts.first)
        #expect(draft.serverID == wireID)
        draft.body = "Edited"
        draft = try await service.upsertDraft(draft, memberID: "member-1", accessToken: "token")
        #expect(draft.serverID == wireID)
        #expect(draft.body == "Edited")
        try await service.deleteDraft(draft, memberID: "member-1", accessToken: "token")
        #expect(await recorder.paths() == Array(repeating: "POST /api/drafts/sync", count: 3))
    }

    @Test
    func upsertUsesServerDraftWhenServerLowercasesTheID() async throws {
        let apiHost = "api-lowercase-id.test"
        let uppercase = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        MockURLProtocol.register(hosts: [apiHost]) { _ in
            try jsonResponse(["drafts": [[
                "draftId": uppercase.lowercased(),
                "body": "Server body",
                "createdAt": "2026-10-11T00:00:00Z",
                "updatedAt": "2026-10-11T00:00:01Z"
            ]]])
        }
        defer { MockURLProtocol.unregister(hosts: [apiHost]) }
        let service = SyncedDraftsService(apiBaseURL: URL(string: "https://\(apiHost)")!, session: mockSession())
        let local = Draft(id: try #require(UUID(uuidString: uppercase)), wireID: uppercase, body: "Local body")

        let synced = try await service.upsertDraft(local, memberID: "member-1", accessToken: "token")

        #expect(synced.body == "Server body")
    }

    @Test
    func imageUpsertPresignsUploadsAndSyncsImageReference() async throws {
        let draftID = UUID()
        let imageData = Data([1, 2, 3])
        let apiHost = "api-upsert.test"
        let uploadHost = "upload-upsert.test"
        let downloadHost = "download-upsert.test"
        let uploadURL = "https://\(uploadHost)/staging/object"
        let downloadURL = "https://\(downloadHost)/linked/object"
        let expectedChecksum = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        let recorder = RequestRecorder()
        MockURLProtocol.register(hosts: [apiHost, uploadHost, downloadHost]) { request in
            await recorder.record(request)
            switch (request.url?.host, request.url?.path, request.httpMethod) {
            case let (host, "/api/draft-images/presign-upload", "POST") where host == apiHost:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                #expect(request.url?.query == "memberId=member-1")
                let body = try #require(bodyData(from: request))
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                #expect(payload?["draftId"] as? String == draftID.uuidString.lowercased())
                #expect(payload?["mimeType"] as? String == "image/png")
                #expect(payload?["sizeBytes"] as? Int == imageData.count)
                #expect(payload?["checksumSHA256"] as? String == expectedChecksum)
                return try jsonResponse([
                    "imageId": "image-1",
                    "uploadUrl": uploadURL,
                    "headers": [
                        "Content-Type": "image/png",
                        "x-amz-meta-checksum-sha256": expectedChecksum
                    ]
                ])
            case let (host, "/staging/object", "PUT") where host == uploadHost:
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
                #expect(request.value(forHTTPHeaderField: "x-amz-meta-checksum-sha256") == expectedChecksum)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case let (host, "/api/drafts/sync", "POST") where host == apiHost:
                let body = try #require(bodyData(from: request))
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let upserts = try #require(payload?["upserts"] as? [[String: Any]])
                #expect(upserts.first?["updatedAt"] != nil)
                let image = try #require(upserts.first?["image"] as? [String: Any])
                #expect(image["imageId"] as? String == "image-1")
                #expect(image["mimeType"] as? String == "image/png")
                #expect(image["sizeBytes"] as? Int == imageData.count)
                #expect(image["checksumSHA256"] as? String == expectedChecksum)
                return try jsonResponse([
                    "drafts": [[
                        "draftId": draftID.uuidString.lowercased(),
                        "body": "Body",
                        "image": [
                            "imageId": "image-1",
                            "downloadUrl": downloadURL,
                            "mimeType": "image/png",
                            "sizeBytes": imageData.count,
                            "checksumSHA256": expectedChecksum
                        ],
                        "createdAt": "2026-09-14T00:00:00Z",
                        "updatedAt": "2026-09-14T00:00:00Z"
                    ]]
                ])
            case let (host, "/linked/object", "GET") where host == downloadHost:
                return (imageData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        defer { MockURLProtocol.unregister(hosts: [apiHost, uploadHost, downloadHost]) }

        let service = SyncedDraftsService(
            apiBaseURL: URL(string: "https://\(apiHost)")!,
            session: mockSession()
        )
        let draft = Draft(
            id: draftID,
            body: "Body",
            imageData: imageData,
            imageFilename: "local.png",
            imageMimeType: "image/png"
        )

        let synced = try await service.upsertDraft(draft, memberID: "member-1", accessToken: "token")

        #expect(synced.imageData == imageData)
        #expect(synced.imageFilename == "image-1.png")
        #expect(synced.imageMimeType == "image/png")
        #expect(synced.remoteImage?.imageId == "image-1")
        #expect(await recorder.paths() == [
            "POST /api/draft-images/presign-upload",
            "PUT /staging/object",
            "POST /api/drafts/sync"
        ])
    }

    @Test
    func listDraftsDownloadsRemoteImageIntoLocalFields() async throws {
        let draftID = UUID()
        let imageData = Data([9, 8, 7])
        let apiHost = "api-list.test"
        let downloadHost = "download-list.test"
        let recorder = RequestRecorder()
        MockURLProtocol.register(hosts: [apiHost, downloadHost]) { request in
            await recorder.record(request)
            switch (request.url?.host, request.url?.path, request.httpMethod) {
            case let (host, "/api/drafts/sync", "POST") where host == apiHost:
                return try jsonResponse([
                    "drafts": [[
                        "draftId": draftID.uuidString,
                        "body": "Remote",
                        "image": [
                            "imageId": "remote-image",
                            "downloadUrl": "https://\(downloadHost)/remote",
                            "mimeType": "image/jpeg",
                            "sizeBytes": imageData.count,
                            "checksumSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        ],
                        "createdAt": "2026-09-14T00:00:00Z",
                        "updatedAt": "2026-09-14T00:00:00Z"
                    ]]
                ])
            case let (host, "/remote", "GET") where host == downloadHost:
                return (imageData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        defer { MockURLProtocol.unregister(hosts: [apiHost, downloadHost]) }

        let service = SyncedDraftsService(
            apiBaseURL: URL(string: "https://\(apiHost)")!,
            session: mockSession()
        )

        let drafts = try await service.listDrafts(memberID: "member-1", accessToken: "token")

        #expect(drafts.first?.imageData == imageData)
        #expect(drafts.first?.imageFilename == "remote-image.jpg")
        #expect(drafts.first?.imageMimeType == "image/jpeg")

        let refreshed = try await service.listDrafts(memberID: "member-1", accessToken: "token")
        #expect(refreshed == drafts)
        #expect(await recorder.paths() == ["POST /api/drafts/sync", "GET /remote", "POST /api/drafts/sync"])
    }
}

private actor RequestRecorder {
    private var values: [String] = []

    func record(_ request: URLRequest) {
        values.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
    }

    func paths() -> [String] {
        values
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) async throws -> (Data, URLResponse)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(hosts: [String], handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        for host in hosts {
            handlers[host] = handler
        }
    }

    static func unregister(hosts: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for host in hosts {
            handlers.removeValue(forKey: host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            guard let host = request.url?.host, let handler = Self.handler(for: host) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (data, response) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private static func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }
}

private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func jsonResponse(_ object: [String: Any]) throws -> (Data, URLResponse) {
    let data = try JSONSerialization.data(withJSONObject: object)
    let response = HTTPURLResponse(
        url: URL(string: "https://api.test")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
}

private func bodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read < 0 { return nil }
        if read == 0 { break }
        data.append(buffer, count: read)
    }
    return data
}
