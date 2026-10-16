import Foundation

struct LinkedInProfile: Codable, Equatable {
    let memberID: String
    let name: String
    let pictureURL: String?
    let email: String?
    let headline: String?
    let localizedHeadline: String?

    enum CodingKeys: String, CodingKey {
        case memberID = "memberId"
        case name
        case pictureURL = "pictureUrl"
        case email
        case headline
        case localizedHeadline
    }

    var displayHeadline: String? {
        let localized = localizedHeadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !localized.isEmpty { return localized }
        let fallback = headline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? nil : fallback
    }
}

struct LinkedInToken: Codable, Equatable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?
    let profile: LinkedInProfile
    let connectedAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken
        case tokenType
        case scope
        case expiresIn
        case profile
        case connectedAt
    }

    var isExpired: Bool {
        guard let expiresIn, expiresIn > 0 else { return false }
        return connectedAt.addingTimeInterval(TimeInterval(expiresIn - 300)) <= Date()
    }
}
