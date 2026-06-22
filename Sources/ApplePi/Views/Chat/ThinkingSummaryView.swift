import SwiftUI

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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(collapsedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(thinkingText)
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var collapsedText: String {
        let normalized = thinkingText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "…" : normalized
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
