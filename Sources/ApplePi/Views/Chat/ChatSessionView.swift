import AppKit
import SwiftUI

/// View for a single open Pi session. The composer is intentionally minimal:
/// one auto-growing input field plus a send icon button on the same row.
struct ChatSessionView: View {
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var session: ChatSession

    @State private var draftText = ""
    @State private var draftHeight: CGFloat = 30

    private var canSend: Bool {
        !session.isSending && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if !session.statusMessage.isEmpty || session.loadError != nil {
                Divider().opacity(0.25)
            }
            MessageListView(session: session)
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
        let controlHeight = max(draftHeight, 30)

        return HStack(alignment: .bottom, spacing: 10) {
            ComposerTextView(
                text: $draftText,
                dynamicHeight: $draftHeight,
                onSubmit: handleSendTapped
            )
            .frame(maxWidth: .infinity, minHeight: controlHeight, maxHeight: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            )

            Button(action: handleSendTapped) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(sendIconStyle)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(sendButtonBackground)
                    )
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canSend)
            .opacity(canSend ? 1 : 0.82)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sendIconStyle: AnyShapeStyle {
        AnyShapeStyle(Color.white.opacity(canSend ? 1 : 0.78))
    }

    private var sendButtonBackground: Color {
        appState.appearance.accentColor.opacity(canSend ? 1 : 0.24)
    }

    private func handleSendTapped() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if appState.sendMessage(prompt, in: session) {
            draftText = ""
            draftHeight = 30
        }
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
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 20)
        textView.focusRingType = .none
        textView.string = text
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: max(dynamicHeight, 30))

        scrollView.documentView = textView
        scrollView.composerTextView = textView
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
        if let composerScrollView = scrollView as? ComposerScrollView {
            composerScrollView.composerTextView = textView
            composerScrollView.needsLayout = true
            composerScrollView.layoutSubtreeIfNeeded()
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
            textView.enclosingScrollView?.needsLayout = true
            textView.enclosingScrollView?.layoutSubtreeIfNeeded()
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
            let next = min(max(usedRect.height + textView.textContainerInset.height * 2, 30), 140)
            if abs(dynamicHeight - next) > 0.5 {
                dynamicHeight = next
            }
        }
    }
}

private final class ComposerScrollView: NSScrollView {
    weak var composerTextView: NSTextView?

    override func layout() {
        super.layout()
        guard let textView = composerTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleWidth = contentView.bounds.width
        guard visibleWidth > 0 else { return }

        textContainer.containerSize = NSSize(width: visibleWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let fittedHeight = max(usedRect.height + textView.textContainerInset.height * 2, textView.minSize.height)
        textView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: fittedHeight)
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
