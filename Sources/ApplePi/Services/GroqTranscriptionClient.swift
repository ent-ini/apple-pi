import Foundation

struct GroqTranscriptionClient {
    func transcribeAudio(at fileURL: URL, apiKey: String, language: String = "ru") async throws -> String {
        let boundary = "ApplePiGroqBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let fileName = fileURL.lastPathComponent
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\"", with: "-")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        var body = Data()
        body.append(formField(named: "model", value: "whisper-large-v3", boundary: boundary))
        body.append(formField(named: "language", value: language, boundary: boundary))
        body.append(fileField(named: "file", fileName: fileName, mimeType: mimeType(for: fileURL), data: try Data(contentsOf: fileURL), boundary: boundary))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GroqTranscriptionError.requestFailed(status: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw GroqTranscriptionError.emptyTranscript
        }
        return text
    }

    private func formField(named name: String, value: String, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
        return data
    }

    private func fileField(named name: String, fileName: String, mimeType: String, data: Data, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        field.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        field.append(data)
        field.append("\r\n".data(using: .utf8)!)
        return field
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

enum GroqTranscriptionError: LocalizedError {
    case invalidResponse
    case requestFailed(status: Int, message: String?)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Groq returned an invalid response."
        case .requestFailed(let status, let message):
            if let message, !message.isEmpty {
                return "Groq transcription failed (\(status)): \(message)"
            }
            return "Groq transcription failed (\(status))."
        case .emptyTranscript:
            return "Groq returned an empty transcript."
        }
    }
}
