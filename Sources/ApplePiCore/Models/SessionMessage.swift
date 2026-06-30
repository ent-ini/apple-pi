import Foundation

package let toolResultDiffSeparator = "\n\n__PI_APP_TOOL_DIFF__\n"

/// Metadata extracted from a `type: "session"` line in a Pi `.jsonl` file.
package struct SessionMeta: Hashable, Sendable {
    package let id: String
    package let workingDirectory: String?
    package let parentSession: String?
    package let displayName: String?

    package init(id: String, workingDirectory: String?, parentSession: String?, displayName: String?) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.parentSession = parentSession
        self.displayName = displayName
    }
}

/// One block inside a message's `content` array. Pi stores text and image
/// blocks the same way Claude does, so we mirror that shape.
package enum ContentBlock: Hashable, Sendable {
    case text(String)
    case thinking(String, signature: String?)
    case image(path: String, mime: String?)
}

/// A single user / assistant / system turn in a Pi session.
package struct Message: Identifiable, Hashable, Sendable {
    package let id: String
    package let role: Role
    package let content: [ContentBlock]
    package let model: String?
    package let timestamp: Date?
    package let parentId: String?

    package init(id: String, role: Role, content: [ContentBlock], model: String?, timestamp: Date?, parentId: String?) {
        self.id = id
        self.role = role
        self.content = content
        self.model = model
        self.timestamp = timestamp
        self.parentId = parentId
    }

    package enum Role: String, Hashable, Sendable {
        case user
        case assistant
        case system
    }
}

/// A tool invocation emitted by the assistant. Pi may use a few shapes
/// (`tool_use`, `tool_call`); we normalise to a single model here.
package enum ToolCall: Identifiable, Hashable, Sendable {
    case function(id: String, name: String, arguments: String)

    package var id: String {
        switch self {
        case .function(let id, _, _): return id
        }
    }

    package var name: String {
        switch self {
        case .function(_, let name, _): return name
        }
    }

    package var arguments: String {
        switch self {
        case .function(_, _, let arguments): return arguments
        }
    }
}

/// The outcome of a tool invocation, paired with the originating call id.
package enum ToolResult: Identifiable, Hashable, Sendable {
    case result(id: String, callId: String, toolName: String?, output: String, isError: Bool)

    package var id: String {
        switch self {
        case .result(let id, _, _, _, _): return id
        }
    }

    package var callId: String {
        switch self {
        case .result(_, let callId, _, _, _): return callId
        }
    }

    package var toolName: String? {
        switch self {
        case .result(_, _, let toolName, _, _): return toolName
        }
    }

    package var output: String {
        switch self {
        case .result(_, _, _, let output, _): return output
        }
    }

    package var isError: Bool {
        switch self {
        case .result(_, _, _, _, let isError): return isError
        }
    }
}

/// Every meaningful line in a Pi session, decoded once into a typed value.
/// The chat view filters and lays these out; non-message events can be
/// rendered as collapsible tool blocks or simply skipped during read-only
/// rendering.
package enum SessionEvent: Identifiable, Hashable, Sendable {
    case meta(SessionMeta, lineIndex: Int)
    case message(Message, lineIndex: Int)
    case toolCall(ToolCall, lineIndex: Int)
    case toolResult(ToolResult, lineIndex: Int)
    case other(type: String, lineIndex: Int)

    /// The line in the source `.jsonl` file this event came from. Used for
    /// pagination and source ordering; SwiftUI identity is based on the
    /// event payload so streamed rows do not flicker when a persisted line
    /// receives its final index.
    package var lineIndex: Int {
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
    package var isVisibleInTranscript: Bool {
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
        "thinking_level_change",
        "session_info"
    ]

    package var id: String {
        switch self {
        case .meta(let meta, _): return "meta:\(meta.id)"
        case .message(let msg, _): return "message:\(msg.id)"
        case .toolCall(let call, _): return "toolCall:\(call.id)"
        case .toolResult(let result, _): return "toolResult:\(result.id)"
        case .other(let type, let index): return "other:\(type):\(index)"
        }
    }
}
