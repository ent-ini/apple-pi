import Foundation

/// Metadata extracted from a `type: "session"` line in a Pi `.jsonl` file.
struct SessionMeta: Hashable, Sendable {
    let id: String
    let workingDirectory: String?
    let parentSession: String?
    let displayName: String?
}

/// One block inside a message's `content` array. Pi stores text and image
/// blocks the same way Claude does, so we mirror that shape.
enum ContentBlock: Hashable, Sendable {
    case text(String)
    case thinking(String, signature: String?)
    case image(path: String, mime: String?)
}

/// A single user / assistant / system turn in a Pi session.
struct Message: Identifiable, Hashable, Sendable {
    let id: String
    let role: Role
    let content: [ContentBlock]
    let model: String?
    let timestamp: Date?
    let parentId: String?

    enum Role: String, Hashable, Sendable {
        case user
        case assistant
        case system
    }
}

/// A tool invocation emitted by the assistant. Pi may use a few shapes
/// (`tool_use`, `tool_call`); we normalise to a single model here.
enum ToolCall: Identifiable, Hashable, Sendable {
    case function(id: String, name: String, arguments: String)

    var id: String {
        switch self {
        case .function(let id, _, _): return id
        }
    }

    var name: String {
        switch self {
        case .function(_, let name, _): return name
        }
    }

    var arguments: String {
        switch self {
        case .function(_, _, let arguments): return arguments
        }
    }
}

/// The outcome of a tool invocation, paired with the originating call id.
enum ToolResult: Identifiable, Hashable, Sendable {
    case result(id: String, callId: String, toolName: String?, output: String, isError: Bool)

    var id: String {
        switch self {
        case .result(let id, _, _, _, _): return id
        }
    }

    var callId: String {
        switch self {
        case .result(_, let callId, _, _, _): return callId
        }
    }

    var toolName: String? {
        switch self {
        case .result(_, _, let toolName, _, _): return toolName
        }
    }

    var output: String {
        switch self {
        case .result(_, _, _, let output, _): return output
        }
    }

    var isError: Bool {
        switch self {
        case .result(_, _, _, _, let isError): return isError
        }
    }
}

/// Every meaningful line in a Pi session, decoded once into a typed value.
/// The chat view filters and lays these out; non-message events can be
/// rendered as collapsible tool blocks or simply skipped during read-only
/// rendering.
enum SessionEvent: Identifiable, Hashable, Sendable {
    case meta(SessionMeta, lineIndex: Int)
    case message(Message, lineIndex: Int)
    case toolCall(ToolCall, lineIndex: Int)
    case toolResult(ToolResult, lineIndex: Int)
    case other(type: String, lineIndex: Int)

    /// The line in the source `.jsonl` file this event came from. Used for
    /// pagination and source ordering; SwiftUI identity is based on the
    /// event payload so streamed rows do not flicker when a persisted line
    /// receives its final index.
    var lineIndex: Int {
        switch self {
        case .meta(_, let index),
             .message(_, let index),
             .toolCall(_, let index),
             .toolResult(_, let index),
             .other(_, let index):
            return index
        }
    }

    /// Whether this event should appear as a transcript row. Runtime
    /// bookkeeping is still parsed and stored so model/thinking/context chips
    /// can use it, but the chat feed should stay focused on messages and
    /// meaningful tool/bookmark events.
    var isVisibleInTranscript: Bool {
        switch self {
        case .meta:
            return false
        case .other(let type, _):
            return !Self.hiddenTranscriptEventTypes.contains(type)
        case .message, .toolCall, .toolResult:
            return true
        }
    }

    private static let hiddenTranscriptEventTypes: Set<String> = [
        "model_change",
        "thinking_level_change"
    ]

    var id: String {
        switch self {
        case .meta(let meta, _): return "meta:\(meta.id)"
        case .message(let msg, _): return "message:\(msg.id)"
        case .toolCall(let call, _): return "toolCall:\(call.id)"
        case .toolResult(let result, _): return "toolResult:\(result.id)"
        case .other(let type, let index): return "other:\(type):\(index)"
        }
    }
}
