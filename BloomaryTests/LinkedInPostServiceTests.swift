import Foundation
import Testing
@testable import Bloomary

@Suite(.serialized)
struct LinkedInPostServiceTests {
    @Test
    func publishSendsDraftID() async throws {
        // Verifies: IOS-002
        let request = try await PostServiceURLProtocol.capture(response: #"{"status":"published","postId":"urn:li:share:1"}"#) {
            _ = try await LinkedInPostService(apiBaseURL: URL(string: "https://post-service.test")!)
                .publish(text: "Hello", credential: LinkedInPostCredential(accessToken: "token", memberID: "member-1"), draftID: "draft-1")
        }
        let body = String(decoding: try #require(PostServiceURLProtocol.body(of: request)), as: UTF8.self)
        #expect(body.contains("name=\"draftId\"\r\n\r\ndraft-1"))
    }

    @Test
    func unscheduleSendsDeleteForDraft() async throws {
        // Verifies: IOS-003
        let request = try await PostServiceURLProtocol.capture(response: "", status: 204) {
            try await LinkedInPostService(apiBaseURL: URL(string: "https://post-service.test")!)
                .unschedule(draftID: "draft-1", credential: LinkedInPostCredential(accessToken: "token", memberID: "member-1"))
        }
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://post-service.test/api/linkedin/schedule?memberId=member-1&draftId=draft-1")
    }
}

private final class PostServiceURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var captured: URLRequest?
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var status = 200

    static func capture(response: String, status: Int = 200, _ call: () async throws -> Void) async throws -> URLRequest {
        captured = nil
        responseBody = Data(response.utf8)
        self.status = status
        URLProtocol.registerClass(PostServiceURLProtocol.self)
        defer { URLProtocol.unregisterClass(PostServiceURLProtocol.self) }
        try await call()
        return try #require(captured)
    }

    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "post-service.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let body = Self.body(of: request) { request.httpBody = body }
        Self.captured = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
