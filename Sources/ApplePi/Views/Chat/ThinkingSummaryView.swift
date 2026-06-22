import SwiftUI

/// Renders the assistant's `thinking` content as a compact single-line
/// disclosure row. Collapsed state shows only the word `Thinking`; expanded
/// state reveals the full text at its natural height.
struct ThinkingSummaryView: View {
    let thinkingText: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Thinking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide thinking" : "Show thinking")

            if isExpanded {
                Text(thinkingText)
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct BouncingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            dot(delay: 0)
            dot(delay: 0.14)
            dot(delay: 0.28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            animate = true
        }
    }

    private func dot(delay: Double) -> some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: 6, height: 6)
            .offset(y: animate ? -4 : 2)
            .animation(
                .easeInOut(duration: 0.45)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animate
            )
    }
}
