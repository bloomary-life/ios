import Foundation

extension JSONDecoder {
    static var app: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            // ISO8601DateFormatter truncates fractions to milliseconds.
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? fractional.parse(value) { return date }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
        }
        return decoder
    }
}

extension JSONEncoder {
    static var app: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            // Keep subsecond ordering for both the server and durable snapshots.
            let seconds = floor(date.timeIntervalSince1970)
            let fraction = Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000)
            let formatter = ISO8601DateFormatter()
            let whole = formatter.string(from: Date(timeIntervalSince1970: seconds))
            var container = encoder.singleValueContainer()
            try container.encode(String(whole.dropLast()) + String(format: ".%09dZ", fraction))
        }
        return encoder
    }
}
