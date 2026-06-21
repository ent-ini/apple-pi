import SwiftUI

/// View for a single open Pi session. In the read-only MVP this is just a
/// list of message bubbles plus a small status line. The next iteration
/// will add an input bar and live tailing.
struct ChatSessionView: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider().opacity(0.25)
            MessageListView(events: session.events)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if !session.statusMessage.isEmpty || session.loadError != nil {
            HStack(spacing: 6) {
                Image(systemName: session.loadError == nil ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(session.loadError == nil ? .secondary : .red)
                Text(session.loadError ?? session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}
