import AppKit
import SwiftUI

/// View for a single open Pi session. The composer is intentionally minimal:
/// one auto-growing input field plus a send icon button on the same row.
struct ChatSessionView: View {
    @ObservedObject var session: ChatSession

    @State private var draftText = ""
    @State private var draftHeight: CGFloat = 36
    @State private var composerNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if !session.statusMessage.isEmpty || session.loadError != nil {
                Divider().opacity(0.25)
            }
            MessageListView(events: session.events)
            Divider().opacity(0.25)
            composerArea
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if !session.statusMessage.isEmpty || session.loadError != nil {
            HStack(spacing: 6) {
                Image(systemName: session.loadError == nil ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(session.loadError == nil ? Color.secondary : Color.red)
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

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    ComposerTextView(
                        text: $draftText,
                        dynamicHeight: $draftHeight,
                        onSubmit: handleSendTapped
                    )
                    .frame(height: draftHeight)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Write a message…")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                    }
                }

                Button(action: handleSendTapped) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let composerNotice {
                Text(composerNotice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func handleSendTapped() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composerNotice = "Send is not wired yet. Next step: POST /send + stream."
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, dynamicHeight: $dynamicHeight, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 24)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        Task { @MainActor in
            context.coordinator.recalculateHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        Task { @MainActor in
            context.coordinator.recalculateHeight(for: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var dynamicHeight: CGFloat
        let onSubmit: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, dynamicHeight: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            self._text = text
            self._dynamicHeight = dynamicHeight
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            Task { @MainActor in
                self.recalculateHeight(for: textView)
            }
        }

        @MainActor
        func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let next = min(max(usedRect.height + textView.textContainerInset.height * 2, 36), 140)
            if abs(dynamicHeight - next) > 0.5 {
                DispatchQueue.main.async {
                    self.dynamicHeight = next
                }
            }
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }
}
