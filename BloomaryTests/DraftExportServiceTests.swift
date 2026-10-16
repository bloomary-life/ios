import Foundation
import Testing
@testable import Bloomary

struct DraftExportServiceTests {
    @Test
    func exportDownloadsTheDraftArchiveToAFile() async throws {
        let zip = Data("PK\u{3}\u{4}archive".utf8)
        ExportURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/api/drafts/export")
            #expect(request.url?.query == "memberId=member-1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/zip"])!
            return (zip, response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExportURLProtocol.self]
        let service = DraftExportService(apiBaseURL: URL(string: "https://api-export.test")!, session: URLSession(configuration: configuration))

        let file = try await service.export(memberID: "member-1", accessToken: "token")

        #expect(file.pathExtension == "zip")
        #expect(try Data(contentsOf: file) == zip)
    }
}

private final class ExportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (data, response) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
