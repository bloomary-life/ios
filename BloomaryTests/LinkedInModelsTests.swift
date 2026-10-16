import Foundation
import Testing
@testable import Bloomary

struct LinkedInModelsTests {
    @Test
    func tokenDecodesBackendCamelCaseKeys() throws {
        let data = Data("""
        {
          "accessToken": "ok",
          "tokenType": "Bearer",
          "scope": "openid profile email",
          "expiresIn": 3600,
          "profile": {
            "memberId": "member-1",
            "name": "Kat Bletsch",
            "pictureUrl": "https://example.com/pic.jpg",
            "email": "kat@example.com",
            "headline": "Fallback headline",
            "localizedHeadline": "Localized headline"
          },
          "connectedAt": "2026-08-26T10:30:00Z"
        }
        """.utf8)

        let token = try JSONDecoder.app.decode(LinkedInToken.self, from: data)
        let expectedDate = try #require(ISO8601DateFormatter().date(from: "2026-08-26T10:30:00Z"))

        #expect(token.accessToken == "ok")
        #expect(token.tokenType == "Bearer")
        #expect(token.expiresIn == 3600)
        #expect(token.profile.memberID == "member-1")
        #expect(token.profile.pictureURL == "https://example.com/pic.jpg")
        #expect(token.profile.displayHeadline == "Localized headline")
        #expect(token.connectedAt == expectedDate)
    }

    @Test
    func profileDisplayHeadlineFallsBackToHeadline() {
        let profile = LinkedInProfile(
            memberID: "member-1",
            name: "Kat Bletsch",
            pictureURL: nil,
            email: nil,
            headline: "Fallback headline",
            localizedHeadline: "   "
        )

        #expect(profile.displayHeadline == "Fallback headline")
    }

    @Test
    func authEnvelopeDecodesBackendCamelCaseKeys() throws {
        let startData = Data("""
        {
          "authUrl": "https://www.linkedin.com/oauth/v2/authorization",
          "state": "state-1",
          "redirectUri": "https://api.bloomary.life/api/linkedin/callback",
          "pollUrl": "/api/linkedin/cli/result?state=state-1"
        }
        """.utf8)
        let start = try JSONDecoder.app.decode(StartResponse.self, from: startData)

        #expect(start.authURL.absoluteString == "https://www.linkedin.com/oauth/v2/authorization")
        #expect(start.state == "state-1")
        #expect(start.redirectURI.absoluteString == "https://api.bloomary.life/api/linkedin/callback")
        #expect(start.pollURL == "/api/linkedin/cli/result?state=state-1")

        let errorData = Data("""
        {
          "status": "error",
          "error": "upstream_error",
          "errorDescription": "linkedin token exchange failed",
          "httpStatus": 401,
          "upstreamBody": "{\\"error\\":\\"invalid_request\\"}"
        }
        """.utf8)
        let envelope = try JSONDecoder.app.decode(ResultEnvelope.self, from: errorData)

        #expect(envelope.status == "error")
        #expect(envelope.errorDescription == "linkedin token exchange failed")
        #expect(envelope.httpStatus == 401)
        #expect(envelope.upstreamBody == "{\"error\":\"invalid_request\"}")

        let apiError = try JSONDecoder.app.decode(APIErrorResponse.self, from: Data("""
        {
          "error": "bad_request",
          "errorDescription": "bad request"
        }
        """.utf8))

        #expect(apiError.error == "bad_request")
        #expect(apiError.errorDescription == "bad request")
    }
}
