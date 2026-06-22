import SwiftUI

/// One chat bubble. User messages are right-aligned with the accent
/// background; assistant messages span almost the full width with a
/// neutral surface so long responses are easy to read.
struct MessageBubble: View {
    @EnvironmentObject private var appState: PiAppState
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
        VStack(alignment: alignment, spacing: 6) {
            if !thinkingText.isEmpty {
                ThinkingSummaryView(thinkingText: thinkingText)
            }
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if message.role == .assistant, let model = message.model {
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
        case .text(let rawText):
            let text = displayText(for: rawText)
            if !text.isEmpty {
                Text(text)
                    .textSelection(.enabled)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .foregroundStyle(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .thinking:
            EmptyView()
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

    private var visibleBlocks: [ContentBlock] {
        message.content.filter {
            if case .thinking = $0 { return false }
            return true
        }
    }

    private var thinkingText: String {
        message.content.compactMap { block in
            if case .thinking(let text, _) = block {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private func displayText(for rawText: String) -> String {
        guard message.role == .user else { return rawText }
        return rawText.replacingOccurrences(
            of: #"^\[source:[^\]]+\](?:\n\[telegram_topic\][\s\S]*?\[/telegram_topic\])?\n?"#,
            with: "",
            options: .regularExpression
        )
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return appState.appearance.accentColor
        case .assistant:
            return Color.gray.opacity(0.10)
        case .system:
            return Color.gray.opacity(0.06)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user:
            return .white
        case .assistant, .system:
            return .primary
        }
    }
}
