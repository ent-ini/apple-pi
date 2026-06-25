import Foundation

struct PiSessionBinding: Sendable {
    let sessionID: String?
    let sessionPath: String?
    let title: String
    let workingDirectory: String?

    var key: String {
        sessionPath ?? sessionID ?? "pending-session"
    }
}

enum PiTurnStreamEvent: Sendable {
    case sessionBound(PiSessionBinding)
    case sessionHeader(SessionMeta)
    case sessionEvents([SessionEvent], isFinal: Bool)
    case streamError(String)
}

enum PiTurnStreamParser {
    static func parseLine(_ rawLine: String) -> PiTurnStreamEvent? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }

        switch type {
        case "session_bound":
            return .sessionBound(
                PiSessionBinding(
                    sessionID: object["sessionId"] as? String,
                    sessionPath: object["filePath"] as? String,
                    title: (object["title"] as? String)?.nilIfBlank ?? "Pi",
                    workingDirectory: object["workingDirectory"] as? String
                )
            )
        case "stream_error":
            return .streamError((object["error"] as? String)?.nilIfBlank ?? "Stream failed.")
        case "session":
            guard let meta = SessionEventParser.decodeSessionMeta(from: object) else { return nil }
            return .sessionHeader(meta)
        case "message_update", "message_end":
            let events = SessionEventParser.decodeMessageEvents(from: object, lineIndex: 0)
            guard !events.isEmpty else { return nil }
            return .sessionEvents(events, isFinal: type == "message_end")
        case "tool_use", "tool_call", "tool_result", "message":
            let events = SessionEventParser.decodeAll(line: trimmed, at: 0)
            guard !events.isEmpty else { return nil }
            return .sessionEvents(events, isFinal: false)
        default:
            return nil
        }
    }
}
