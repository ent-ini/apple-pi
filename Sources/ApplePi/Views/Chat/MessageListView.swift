import SwiftUI

/// Scrollable list of `SessionEvent`s. Renders only message events for now.
/// As new events arrive the list auto-scrolls to the bottom, but only if the
/// user is already near the bottom (so reading older messages does not get
/// hijacked by streaming).
struct MessageListView: View {
    @ObservedObject var session: ChatSession

    @State private var isAnchoredToBottom = true

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(displayedEvents) { event in
                            switch event {
                            case .message(let message, _):
                                MessageBubble(message: message)
                                    .id(event.id)
                            case .toolCall, .toolResult, .meta, .other:
                                EmptyView()
                            }
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
                .onAppear {
                    scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchorID = "chat.list.bottom"
    private static let pendingAssistantAnchorID = "chat.list.pending.assistant"

    private var displayedEvents: [SessionEvent] {
        session.events.filter {
            if case .message = $0 { return true }
            return false
        }
    }

    private var showsPendingAssistantPlaceholder: Bool {
        guard session.isSending else { return false }
        guard let lastMessageEvent = displayedEvents.last else { return true }
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

    private func scrollToBottomIfNeeded(using scrollProxy: ScrollViewProxy) {
        guard isAnchoredToBottom else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }
}
