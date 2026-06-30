import Foundation

public struct PiSessionBinding: Sendable {
    public let sessionID: String?
    public let sessionPath: String?
    public let title: String
    public let workingDirectory: String?

    public init(sessionID: String?, sessionPath: String?, title: String, workingDirectory: String?) {
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.title = title
        self.workingDirectory = workingDirectory
    }

    public var key: String {
        sessionPath ?? sessionID ?? "pending-session"
    }
}

public enum PiTurnStreamEvent: Sendable {
    case sessionBound(PiSessionBinding)
    case sessionHeader(SessionMeta)
    case sessionEvents([SessionEvent], isFinal: Bool)
    case turnEnd
    case agentEnd
    case abort
    case outputComplete
    case streamError(String)
}

public enum PiTurnStreamParser {
    public static func parseLine(_ rawLine: String) -> PiTurnStreamEvent? {
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
        case "session_info":
            let events = SessionEventParser.decodeAll(line: trimmed, at: 0)
            guard !events.isEmpty else { return nil }
            return .sessionEvents(events, isFinal: false)
        case "message_update", "message_end":
            let events = SessionEventParser.decodeMessageEvents(from: object, lineIndex: 0)
            guard !events.isEmpty else { return nil }
            return .sessionEvents(events, isFinal: type == "message_end")
        case "turn_end":
            return .turnEnd
        case "agent_end":
            return .agentEnd
        case "abort":
            return .abort
        case "output_complete":
            return .outputComplete
        case "tool_use", "tool_call", "tool_result", "message":
            let events = SessionEventParser.decodeAll(line: trimmed, at: 0)
            guard !events.isEmpty else { return nil }
            return .sessionEvents(events, isFinal: false)
        default:
            return nil
        }
    }
}
