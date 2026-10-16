import Foundation
import Testing
@testable import Bloomary

struct MultipartFormDataBuilderTests {
    @Test
    func buildsExpectedFormBody() throws {
        let builder = MultipartFormDataBuilder(boundary: "test-boundary")
        let data = builder.body(fields: ["commentary": "Hello"])
        let body = try #require(String(data: data, encoding: .utf8))

        #expect(body.contains("--test-boundary\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"commentary\"\r\n\r\n"))
        #expect(body.contains("Hello\r\n"))
        #expect(body.hasSuffix("--test-boundary--\r\n"))
    }
}
