import Foundation

struct GroqTranscriptionClient {
    /// The hardcoded Groq audio transcription endpoint. The URL is
    /// constructed lazily and falls back to a local file URL if the
    /// constant ever fails to parse, so `transcribeAudio` never crashes
    /// on URL initialisation. The fallback branch is unreachable for a
    /// well-formed HTTPS literal.
    static let transcriptionURL: URL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")
        ?? URL(fileURLWithPath: "/")

    func transcribeAudio(at fileURL: URL, apiKey: String, language: String = "ru") async throws -> String {
        let boundary = "ApplePiGroqBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // The filename goes directly into a `Content-Disposition: form-data;
        // name="file"; filename="…"` header. Apply a strict whitelist so
        // unusual Unicode, semicolons, or control bytes cannot confuse
        // the server-side multipart parser.
        let fileName = MultipartFilenameSanitizer.sanitize(
            fileURL.lastPathComponent,
            placeholder: "audio"
        )

        let fileData = try Data(contentsOf: fileURL)
        request.httpBody = Self.makeTranscriptionMultipartBody(
            fileName: fileName,
            mimeType: mimeType(for: fileURL),
            fileData: fileData,
            language: language,
            boundary: boundary
        )

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

    private static func formField(named name: String, value: String, boundary: String) -> Data {
        // Use `Data(... .utf8)` rather than optional UTF-8 conversion
        // — the former never fails for a Swift `String`, so we can
        // drop the force unwrap without any behaviour change. Marked
        // `static` so the test-friendly `makeTranscriptionMultipartBody`
        // can call it without needing an instance.
        var data = Data()
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
        return data
    }

    private static func fileField(named name: String, fileName: String, mimeType: String, data: Data, boundary: String) -> Data {
        var field = Data()
        field.append(Data("--\(boundary)\r\n".utf8))
        field.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        field.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        field.append(data)
        field.append(Data("\r\n".utf8))
        return field
    }

    /// Builds the full multipart body for a Whisper transcription
    /// request. Exposed as a static helper so the test suite can pin
    /// the wire format (in particular the sanitised filename and the
    /// field ordering) without having to mock `URLSession`.
    static func makeTranscriptionMultipartBody(
        fileName: String,
        mimeType: String,
        fileData: Data,
        language: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(formField(named: "model", value: "whisper-large-v3", boundary: boundary))
        body.append(formField(named: "language", value: language, boundary: boundary))
        body.append(fileField(named: "file", fileName: fileName, mimeType: mimeType, data: fileData, boundary: boundary))
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
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
