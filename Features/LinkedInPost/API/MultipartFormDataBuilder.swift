import Foundation

struct MultipartFormDataBuilder {
    let boundary: String

    func body(fields: [String: String], file: MultipartFormFile? = nil) -> Data {
        var data = Data()
        for (key, value) in fields {
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            data.append("\(value)\r\n")
        }
        if let file {
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
            data.append("Content-Type: \(file.mimeType)\r\n\r\n")
            data.append(file.data)
            data.append("\r\n")
        }
        data.append("--\(boundary)--\r\n")
        return data
    }
}

struct MultipartFormFile {
    let fieldName: String
    let filename: String
    let mimeType: String
    let data: Data
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
