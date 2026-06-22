import SwiftUI

private let messageBubbleMaxWidth: CGFloat = 420

private struct BubbleWidthModifier: ViewModifier {
    let prefersCompactWidth: Bool
    let alignment: Alignment

    func body(content: Content) -> some View {
        if prefersCompactWidth {
            content
                .fixedSize(horizontal: true, vertical: false)
        } else {
            content
                .frame(maxWidth: messageBubbleMaxWidth, alignment: alignment)
        }
    }
}

/// One chat bubble. User messages are right-aligned with the accent
/// background; assistant messages span almost the full width with a
/// neutral surface so long responses are easy to read.
struct MessageBubble: View {
    @EnvironmentObject private var appState: PiAppState
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 90)
                bubbleColumn(alignment: .trailing)
            } else {
                bubbleColumn(alignment: .leading)
                Spacer(minLength: 90)
            }
        }
    }

    @ViewBuilder
    private func bubbleColumn(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if !thinkingText.isEmpty {
                ThinkingSummaryView(thinkingText: thinkingText)
            }
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLastVisibleBlock: index == visibleBlocks.count - 1)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock, isLastVisibleBlock: Bool) -> some View {
        switch block {
        case .text(let rawText):
            let text = displayText(for: rawText)
            if !text.isEmpty {
                bubbleSurface(
                    isLastVisibleBlock: isLastVisibleBlock,
                    prefersCompactWidth: prefersCompactWidth(for: text)
                ) {
                    Text(text)
                        .textSelection(.enabled)
                        .font(.body)
                }
            }
        case .thinking:
            EmptyView()
        case .image:
            bubbleSurface(isLastVisibleBlock: isLastVisibleBlock, prefersCompactWidth: true) {
                Text("[image]")
                    .font(.body.monospaced())
            }
        }
    }

    private func bubbleSurface<Content: View>(
        isLastVisibleBlock: Bool,
        prefersCompactWidth: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let showsTimestamp = isLastVisibleBlock && formattedTime != nil

        return VStack(alignment: .leading, spacing: 0) {
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, showsTimestamp ? 24 : 10)
        .background(bubbleBackground)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if isLastVisibleBlock, let timestamp = formattedTime {
                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(timestampColor)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
        .modifier(BubbleWidthModifier(prefersCompactWidth: prefersCompactWidth, alignment: bubbleFrameAlignment))
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
        .joined(separator: "\n\n---\n\n")
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
            return appState.appearance.accentForegroundColor
        case .assistant, .system:
            return .primary
        }
    }

    private var formattedTime: String? {
        guard let timestamp = message.timestamp else { return nil }
        return Self.timeFormatter.string(from: timestamp)
    }

    private var timestampColor: Color {
        switch message.role {
        case .user:
            return appState.appearance.accentForegroundColor.opacity(0.82)
        case .assistant, .system:
            return .secondary
        }
    }

    private var bubbleFrameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private func prefersCompactWidth(for text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count <= 42 && !normalized.contains("\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
