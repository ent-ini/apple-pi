import Foundation

/// Decodes a Pi `.jsonl` session file into a typed `[SessionEvent]` array.
/// We deliberately read the whole file at once for the read-only chat view;
/// the live tail in `ChatSession` will append events incrementally using
/// the same `decode(line:at:)` entry point.
enum SessionEventParser {
    /// Read every line from disk and parse it.
    static func parse(fileURL: URL) throws -> [SessionEvent] {
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parse(lines: lines)
    }

    /// Parse a list of raw lines. Blank lines are skipped silently.
    static func parse(lines: [String]) -> [SessionEvent] {
        var events: [SessionEvent] = []
        events.reserveCapacity(lines.count)

        for (index, raw) in lines.enumerated() {
            guard let event = decode(line: raw, at: index) else { continue }
            events.append(event)
        }
        return events
    }

    /// Decode a single line and return the corresponding event, or nil if
    /// the line is blank, malformed, or of a type we do not care about.
    /// The caller is responsible for assigning the line index based on its
    /// own tail offset.
    static func decode(line raw: String, at lineIndex: Int) -> SessionEvent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "session":
            guard let meta = decodeSessionMeta(from: object) else { return nil }
            return .meta(meta, lineIndex: lineIndex)
        case "message":
            guard let message = decodeMessage(from: object) else { return nil }
            return .message(message, lineIndex: lineIndex)
        case "tool_use", "tool_call":
            guard let call = parseToolCall(object) else { return nil }
            return .toolCall(call, lineIndex: lineIndex)
        case "tool_result":
            guard let result = parseToolResult(object) else { return nil }
            return .toolResult(result, lineIndex: lineIndex)
        default:
            return .other(type: type, lineIndex: lineIndex)
        }
    }

    // MARK: - Field decoders

    static func decodeSessionMeta(from object: [String: Any]) -> SessionMeta? {
        let id = stringValue(from: object, keys: ["sessionId", "sessionID", "id"])
        let cwd = stringValue(from: object, keys: ["cwd", "workingDirectory"])
        let parent = stringValue(from: object, keys: ["parentSession"])
        let name = stringValue(from: object, keys: ["name", "displayName", "title"])
        // Keep the meta block even if most fields are missing — the session
        // file's first line is usually the session declaration and we want
        // the working directory even when no session id is set yet.
        return SessionMeta(
            id: id ?? UUID().uuidString,
            workingDirectory: cwd,
            parentSession: parent,
            displayName: name
        )
    }

    static func decodeMessage(from object: [String: Any]) -> Message? {
        guard let payload = object["message"] as? [String: Any] else { return nil }
        guard let roleString = payload["role"] as? String,
              let role = Message.Role(rawValue: roleString)
        else { return nil }

        let id = (object["id"] as? String)
            ?? (payload["id"] as? String)
            ?? (payload["responseId"] as? String)
            ?? (object["responseId"] as? String)
            ?? UUID().uuidString
        let content = parseContent(payload["content"])
        let model = (payload["model"] as? String) ?? (payload["modelId"] as? String)
        let parentId = (object["parentId"] as? String) ?? (payload["parentId"] as? String)
        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
            ?? (payload["timestamp"] as? String).flatMap(parseTimestamp)

        return Message(
            id: id,
            role: role,
            content: content,
            model: model,
            timestamp: timestamp,
            parentId: parentId
        )
    }

    private static func parseContent(_ value: Any?) -> [ContentBlock] {
        if let text = value as? String {
            return text.isEmpty ? [] : [.text(text)]
        }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { block in
                if let text = block["text"] as? String {
                    return text.isEmpty ? nil : .text(text)
                }
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    return text.isEmpty ? nil : .text(text)
                }
                if (block["type"] as? String) == "image" {
                    if let source = block["source"] as? [String: Any],
                       let path = source["path"] as? String {
                        return .image(path: path, mime: block["mimeType"] as? String)
                    }
                    if let path = block["path"] as? String {
                        return .image(path: path, mime: block["mimeType"] as? String)
                    }
                }
                return nil
            }
        }
        return []
    }

    private static func parseToolCall(_ object: [String: Any]) -> ToolCall? {
        let id = (object["id"] as? String) ?? UUID().uuidString
        let name = (object["name"] as? String) ?? (object["toolName"] as? String) ?? "tool"
        let arguments: String
        if let input = object["input"] {
            if JSONSerialization.isValidJSONObject(input),
               let data = try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                arguments = str
            } else {
                arguments = "\(input)"
            }
        } else {
            arguments = ""
        }
        return .function(id: id, name: name, arguments: arguments)
    }

    private static func parseToolResult(_ object: [String: Any]) -> ToolResult? {
        let callId = (object["toolCallId"] as? String) ?? (object["callId"] as? String) ?? ""
        let id = (object["id"] as? String) ?? UUID().uuidString
        let isError = (object["isError"] as? Bool) ?? false
        let output: String
        if let content = object["content"] {
            if let text = content as? String {
                output = text
            } else if let data = try? JSONSerialization.data(
                withJSONObject: content,
                options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]
            ), let str = String(data: data, encoding: .utf8) {
                output = str
            } else {
                output = "\(content)"
            }
        } else {
            output = ""
        }
        return .result(id: id, callId: callId, output: output, isError: isError)
    }

    private static func stringValue(from object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        timestampParsers.parse(value)
    }

    private static let timestampParsers = TimestampParsers()
}

private final class TimestampParsers: @unchecked Sendable {
    private let lock = NSLock()
    private let withFractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.withFractional = withFractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.plain = plain
    }

    func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = withFractional.date(from: value) { return date }
        return plain.date(from: value)
    }
}
