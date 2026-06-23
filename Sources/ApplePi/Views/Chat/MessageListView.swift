import SwiftUI

/// Scrollable list of `SessionEvent`s. Renders message bubbles for chat
/// turns and compact disclosure rows for tool calls, tool results, and
/// non-message bookkeeping events (session meta, labels, branch summaries,
/// custom entries). As new events arrive the list auto-scrolls to the
/// bottom, but only if the user is already near the bottom (so reading
/// older messages does not get hijacked by streaming).
struct MessageListView: View {
    @ObservedObject var session: ChatSession

    @State private var isAnchoredToBottom = true
    @State private var hasCompletedInitialPlacement = false

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(displayedEvents) { event in
                            eventRow(for: event)
                                .id(event.id)
                        }
                        if showsPendingAssistantPlaceholder {
                            HStack(alignment: .top, spacing: 0) {
                                BouncingDotsView()
                                Spacer(minLength: 60)
                            }
                            .id(Self.pendingAssistantAnchorID)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(20)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .onChange(of: session.events.count) { _, _ in
                    scrollToBottomIfNeeded(using: scrollProxy)
                }
                .onChange(of: session.streamRevision) { _, _ in
                    scrollToBottomIfNeeded(using: scrollProxy)
                }
                .opacity(hasCompletedInitialPlacement ? 1 : 0)
                .onChange(of: session.isLoading) { _, isLoading in
                    if isLoading {
                        hasCompletedInitialPlacement = false
                        return
                    }
                    scrollToBottomSettled(using: scrollProxy, animated: false, completesInitialPlacement: true)
                }
                .onAppear {
                    hasCompletedInitialPlacement = false
                    if session.isLoading {
                        return
                    }
                    scrollToBottomSettled(using: scrollProxy, animated: false, completesInitialPlacement: true)
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(for event: SessionEvent) -> some View {
        switch event {
        case .message(let message, _):
            MessageBubble(message: message)
        case .toolCall(let call, _):
            ToolEventRow(
                kind: .toolCall(name: call.name, arguments: call.arguments)
            )
        case .toolResult(let result, _):
            ToolEventRow(
                kind: .toolResult(
                    name: result.toolName,
                    callId: result.callId,
                    output: result.output,
                    isError: result.isError
                )
            )
        case .meta(let meta, _):
            ToolEventRow(
                kind: .meta(
                    displayName: meta.displayName,
                    workingDirectory: meta.workingDirectory,
                    parentSession: meta.parentSession
                )
            )
        case .other(let type, _):
            ToolEventRow(kind: .other(type: type))
        }
    }

    private static let bottomAnchorID = "chat.list.bottom"
    private static let pendingAssistantAnchorID = "chat.list.pending.assistant"

    private var displayedEvents: [SessionEvent] {
        session.events
    }

    private var showsPendingAssistantPlaceholder: Bool {
        guard session.isSending else { return false }
        guard let lastMessageEvent = lastMessageEvent else { return true }
        guard case .message(let message, let lineIndex) = lastMessageEvent else { return true }

        if message.role == .user, lineIndex == Int.max - 1 {
            return true
        }

        guard message.role == .assistant, lineIndex == Int.max else { return false }
        return !message.content.contains { block in
            switch block {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(let text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image:
                return true
            }
        }
    }

    /// Last message event ignoring tool/meta/other rows, so streaming
    /// activity drives the bouncing-dots placeholder the same way it did
    /// before tool rows started rendering.
    private var lastMessageEvent: SessionEvent? {
        for event in session.events.reversed() {
            if case .message = event { return event }
        }
        return nil
    }

    private func scrollToBottomIfNeeded(using scrollProxy: ScrollViewProxy) {
        guard isAnchoredToBottom else { return }
        scrollToBottom(using: scrollProxy, animated: true)
    }

    private func scrollToBottom(using scrollProxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func scrollToBottomSettled(using scrollProxy: ScrollViewProxy, animated: Bool, completesInitialPlacement: Bool) {
        scrollToBottom(using: scrollProxy, animated: animated)
        DispatchQueue.main.async {
            scrollToBottom(using: scrollProxy, animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scrollToBottom(using: scrollProxy, animated: false)
            if completesInitialPlacement {
                hasCompletedInitialPlacement = true
            }
        }
    }
}

// MARK: - ToolEventRow

/// Compact, single-line disclosure for non-message events: tool calls,
/// tool results, session meta, and bookkeeping entries (label changes,
/// branch summaries, custom messages, etc.). The row stays out of the
/// way but the user can expand it to inspect raw payloads.
struct ToolEventRow: View {
    enum Kind {
        case toolCall(name: String, arguments: String)
        case toolResult(name: String?, callId: String, output: String, isError: Bool)
        case meta(displayName: String?, workingDirectory: String?, parentSession: String?)
        case other(type: String)

        var label: String {
            switch self {
            case .toolCall(let name, _):
                return "tool · \(name)"
            case .toolResult(let name, _, _, let isError):
                let display = name.map { "tool · \($0)" } ?? "tool result"
                return isError ? "\(display) · error" : display
            case .meta(let displayName, let cwd, _):
                var parts: [String] = ["session"]
                if let displayName, !displayName.isEmpty { parts.append(displayName) }
                if let cwd, !cwd.isEmpty { parts.append(cwd) }
                return parts.joined(separator: " · ")
            case .other(let type):
                return "event · \(type)"
            }
        }

        var iconName: String {
            switch self {
            case .toolCall: return "wrench.and.screwdriver"
            case .toolResult(_, _, _, let isError):
                return isError ? "exclamationmark.triangle" : "checkmark.circle"
            case .meta: return "info.circle"
            case .other: return "doc.text"
            }
        }

        var tint: Color {
            switch self {
            case .toolCall: return .secondary
            case .toolResult(_, _, _, let isError):
                return isError ? .red : .secondary
            case .meta: return .secondary
            case .other: return .secondary
            }
        }

        var detail: String? {
            switch self {
            case .toolCall(_, let arguments):
                return summary(of: arguments, fallback: "(no arguments)")
            case .toolResult(_, _, let output, _):
                return summary(of: output, fallback: "(empty)")
            case .meta(_, _, let parent):
                return parent.map { "forked from \($0)" }
            case .other:
                return nil
            }
        }

        var expandedBody: String? {
            switch self {
            case .toolCall(_, let arguments):
                return arguments.isEmpty ? nil : arguments
            case .toolResult(_, _, let output, _):
                return output.isEmpty ? nil : output
            case .meta(let displayName, let cwd, let parent):
                var pieces: [String] = []
                if let displayName, !displayName.isEmpty { pieces.append("name: \(displayName)") }
                if let cwd, !cwd.isEmpty { pieces.append("cwd: \(cwd)") }
                if let parent, !parent.isEmpty { pieces.append("parent: \(parent)") }
                return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
            case .other:
                return nil
            }
        }

        private func summary(of text: String, fallback: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return fallback }
            let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
            if oneLine.count <= 80 { return oneLine }
            let endIndex = oneLine.index(oneLine.startIndex, offsetBy: 80)
            return "\(oneLine[..<endIndex])…"
        }
    }

    let kind: Kind

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            row
                .frame(maxWidth: 520, alignment: .leading)
            Spacer(minLength: 60)
        }
    }

    @ViewBuilder
    private var row: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard kind.expandedBody != nil else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(kind.tint)
                    Text(kind.label)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if kind.expandedBody != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(kind.expandedBody == nil ? kind.label : (isExpanded ? "Hide details" : "Show details"))

            if let detail = kind.detail, !isExpanded {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isExpanded, let body = kind.expandedBody {
                Text(body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
