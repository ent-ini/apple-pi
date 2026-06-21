import SwiftUI

/// One chat bubble. User messages are right-aligned with the accent
/// background; assistant messages span almost the full width with a
/// neutral surface so long responses are easy to read. The MVP uses
/// `Text(verbatim:)` so the rendered output matches the source file
/// exactly; the next iteration swaps in markdown rendering via WKWebView.
struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 60)
                bubbleColumn(alignment: .trailing)
            } else {
                bubbleColumn(alignment: .leading)
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if let model = message.model {
                Text(model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .foregroundStyle(textColor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .image:
            Text("[image]")
                .font(.body.monospaced())
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .foregroundStyle(textColor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.18)
        case .assistant:
            return Color.gray.opacity(0.10)
        case .system:
            return Color.gray.opacity(0.06)
        }
    }

    private var textColor: Color { .primary }
}
