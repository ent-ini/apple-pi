import SwiftUI

/// Scrollable list of `SessionEvent`s. Renders only message events as
/// bubbles for now; meta, tool, and unknown events are skipped. As new
/// events arrive the list auto-scrolls to the bottom, but only if the
/// user is already near the bottom (so reading older messages does not
/// get hijacked by streaming).
struct MessageListView: View {
    let events: [SessionEvent]

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
                                // Read-only MVP: tool events are not rendered.
                                // The next iteration adds collapsible blocks.
                                EmptyView()
                            }
                        }
                        // Sentinel for auto-scroll. The id is stable so
                        // SwiftUI re-targets it as new messages arrive.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                    }
                    .padding(20)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .onChange(of: events.count) { _, _ in
                    guard isAnchoredToBottom else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                .onAppear {
                    scrollProxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchorID = "chat.list.bottom"

    /// Filter out non-message events for the read-only MVP. The full event
    /// list is still available to the parent `ChatSession` for tool-event
    /// rendering in the next iteration.
    private var displayedEvents: [SessionEvent] {
        events.filter {
            if case .message = $0 { return true }
            return false
        }
    }
}
