import Foundation

enum NaturalizeError: LocalizedError {
    case emptyText
    case missingAPIKey
    case server(String)

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Post is empty."
        case .missingAPIKey:
            return "Add your AI API key in Settings first."
        case .server(let message):
            return message
        }
    }
}

final class NaturalizeService: Sendable {
    private let interactionsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    private let model = "gemini-3.8-flash"

    func naturalize(text: String, settings: AISettings) async throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw NaturalizeError.emptyText }
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NaturalizeError.missingAPIKey
        }

        var request = URLRequest(url: interactionsURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "store": false,
            "system_instruction": naturalizePrompt(language: settings.postLanguage),
            "input": "Edit this LinkedIn draft:\n\n" + body,
            "generation_config": ["temperature": 0.2]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder.app.decode(GeminiAPIErrorResponse.self, from: data) {
                let hint = [400, 401, 403].contains((response as? HTTPURLResponse)?.statusCode ?? 0)
                    ? " Check that your Gemini key is active and current; update it in Settings if rotated or deleted." : ""
                throw NaturalizeError.server(apiError.error.message + hint)
            }
            throw NaturalizeError.server("AI edit failed.")
        }
        let result = try JSONDecoder.app.decode(InteractionResponse.self, from: data)
        let text = result.steps.filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }.filter { $0.type == "text" }
            .compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NaturalizeError.server("AI edit returned no text.") }
        return Self.boldHighlights(text)
    }

    private static func boldHighlights(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let content = (text as NSString).substring(with: match.range(at: 1))
            let bold = String(content.unicodeScalars.map { scalar -> Character in
                let code = Int(scalar.value)
                let offset: Int?
                switch code {
                case 65...90: offset = 0x1D5D4 - 65
                case 97...122: offset = 0x1D5EE - 97
                case 48...57: offset = 0x1D7EC - 48
                default: offset = nil
                }
                return Character(offset.flatMap { UnicodeScalar(code + $0) } ?? scalar)
            })
            result.replaceCharacters(in: match.range, with: bold)
        }
        return result as String
    }
}

func naturalizePrompt(language: String) -> String {
    let target = language == PostLanguage.sameAsDraft
        ? "Write the result in the same language as the draft."
        : "Write the result in \(language). The draft may be in any language; if it is not in \(language), translate it into natural \(language) without changing the meaning."
    let languageName = language == PostLanguage.sameAsDraft ? "the draft's language" : language
    return "You receive a LinkedIn post draft from the user. \(target) Draft a LinkedIn post, fix grammar, make the \(languageName) sound natural, preserve the user's style, and do not modify meaning. Make the result sound more like the user: preserve their voice, rhythm, directness, emotional logic, and slightly non-native but clear phrasing when it adds authenticity. Make it hooked in the first 2-3 sentences. Carefully compress the draft: eliminate unnecessary words and replace longer words with shorter ones, ensuring the post retains its original meaning, information, and tone. Wrap any moments you want highlighted — results, numbers, surprising facts, punchy one-liners — in double asterisks like **this**. End the post with exactly three relevant hashtags on one final line. Replace or deduplicate any existing hashtags so the final post contains exactly three hashtags total. Do not explain your edits or wrap the answer in quotes. Return only the edited post."
}

private struct InteractionResponse: Decodable {
    let steps: [Step]
    struct Step: Decodable {
        let type: String
        let content: [Part]?
    }
    struct Part: Decodable {
        let type: String
        let text: String?
    }
}

private struct GeminiAPIErrorResponse: Decodable {
    let error: GeminiAPIError

    struct GeminiAPIError: Decodable {
        let message: String
    }
}
