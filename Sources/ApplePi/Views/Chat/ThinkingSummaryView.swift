import SwiftUI
import ApplePiCore
import ApplePiRemote

/// Renders the assistant's `thinking` content as a compact single-line
/// disclosure row. Collapsed state shows only the word `Thinking`; expanded
/// state reveals the full text at its natural height.
struct ThinkingSummaryView: View {
    @Environment(\.chatEnsureVisible) private var ensureVisible
    let thinkingText: String
    let visibilityID: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                let willExpand = !isExpanded
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
                if willExpand {
                    ensureVisible(visibilityID)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .chatVisibilityTarget(visibilityID)
    }
}

struct BouncingDotsView: View {
    private let dotSize: CGFloat = 6
    private let dotSpacing: CGFloat = 5
    private let period: Double = 1.2          // full cycle in seconds
    private let phaseStep: Double = 0.18       // wave offset between dots
    private let containerHeight: CGFloat = 18  // enough vertical room so dots never feel "pinned" to the bubble's top edge

    var body: some View {
        // TimelineView drives all three dots from a single time source.
        // This keeps them perfectly in sync and survives parent re-renders
        // during streaming, which used to desync the previous per-dot
        // .repeatForever animations and look "random".
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: dotSize, height: dotSize)
                        .modifier(BounceWaveModifier(
                            elapsed: elapsed,
                            period: period,
                            phase: Double(index) * phaseStep
                        ))
                }
            }
            .frame(
                width: dotSize * 3 + dotSpacing * 2,
                height: containerHeight,
                alignment: .center
            )
        }
        .accessibilityLabel("Assistant is typing")
    }
}

private struct BounceWaveModifier: ViewModifier {
    let elapsed: TimeInterval
    let period: Double
    let phase: Double

    func body(content: Content) -> some View {
        // Cosine wave in [0, 1] — smooth, predictable, no sticking at extremes.
        let progress = (elapsed.truncatingRemainder(dividingBy: period) / period) - phase
        let angle = 2.0 * .pi * progress.truncatingRemainder(dividingBy: 1.0)
        let wave = (1.0 - cos(angle)) / 2.0
        let scale = 0.55 + 0.45 * wave   // 0.55 ... 1.0
        let opacity = 0.35 + 0.65 * wave // 0.35 ... 1.0
        return content
            .scaleEffect(scale)
            .opacity(opacity)
    }
}
