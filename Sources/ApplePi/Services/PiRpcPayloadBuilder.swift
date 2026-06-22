import Foundation

struct PiRpcPromptPayload: Sendable {
    let message: String
    let images: [PiRpcImageContent]
}

struct PiRpcImageContent: Encodable, Sendable {
    let type = "image"
    let data: String
    let mimeType: String
}

enum PiRpcPayloadBuilder {
    private static let maxInlineTextBytes = 200_000

    static func build(prompt: String, attachments: [ChatAttachment]) -> PiRpcPromptPayload {
        var prefix = ""
        var images: [PiRpcImageContent] = []

        for attachment in attachments {
            if attachment.kind == .image {
                if let mimeType = attachment.mimeType,
                   let imageData = try? Data(contentsOf: attachment.fileURL) {
                    images.append(
                        PiRpcImageContent(
                            data: imageData.base64EncodedString(),
                            mimeType: mimeType
                        )
                    )
                    prefix += "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\"></file>\n"
                } else {
                    prefix += "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">[Image attachment: \(attachment.displayName.xmlEscapedForPrompt)]</file>\n"
                }
                continue
            }

            if let data = try? Data(contentsOf: attachment.fileURL),
               data.count <= maxInlineTextBytes,
               let text = String(data: data, encoding: .utf8),
               !text.contains("\u{0000}") {
                prefix += "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">\n\(text)\n</file>\n"
                continue
            }

            let fallback = attachment.kind == .audio
                ? "[Audio attachment: \(attachment.displayName)]"
                : "[Binary file attached: \(attachment.displayName)]"
            prefix += "<file name=\"\(attachment.filePath.xmlEscapedForPrompt)\">\(fallback.xmlEscapedForPrompt)</file>\n"
        }

        let message = prefix.isEmpty ? prompt : "\(prefix)\n\(prompt)"
        return PiRpcPromptPayload(message: message, images: images)
    }
}

private extension String {
    var xmlEscapedForPrompt: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
