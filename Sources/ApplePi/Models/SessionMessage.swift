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
}

/// The outcome of a tool invocation, paired with the originating call id.
enum ToolResult: Identifiable, Hashable, Sendable {
    case result(id: String, callId: String, output: String, isError: Bool)

    var id: String {
        switch self {
        case .result(let id, _, _, _): return id
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
    /// stable SwiftUI identity so messages do not jump around as new lines
    /// are appended.
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

    var id: String {
        switch self {
        case .meta(let meta, let index): return "meta:\(meta.id):\(index)"
        case .message(let msg, let index): return "message:\(msg.id):\(index)"
        case .toolCall(let call, let index): return "toolCall:\(call.id):\(index)"
        case .toolResult(let result, let index): return "toolResult:\(result.id):\(index)"
        case .other(let type, let index): return "other:\(type):\(index)"
        }
    }
}
