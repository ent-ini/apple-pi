import AppKit
import SwiftUI

struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: AppShortcut

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onCapture = { newShortcut in
            context.coordinator.shortcut.wrappedValue = newShortcut
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.shortcut = shortcut
    }

    final class Coordinator {
        let shortcut: Binding<AppShortcut>

        init(shortcut: Binding<AppShortcut>) {
            self.shortcut = shortcut
        }
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: AppShortcut = AppShortcutAction.newSession.defaultShortcut {
        didSet { updateAppearance() }
    }

    var onCapture: ((AppShortcut) -> Void)?

    private var isRecording = false {
        didSet { updateAppearance() }
    }
    private var localKeyMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        isBordered = true
        focusRingType = .default
        target = self
        action = #selector(beginRecording)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        isBordered = true
        focusRingType = .default
        target = self
        action = #selector(beginRecording)
        updateAppearance()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        window?.makeFirstResponder(self)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            guard let captured = AppShortcut(capturing: event) else {
                NSSound.beep()
                return nil
            }
            self.shortcut = captured
            self.stopRecording()
            self.onCapture?(captured)
            return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !isRecording else { return }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, isRecording {
            stopRecording()
        }
        return result
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    private func stopRecording() {
        isRecording = false
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func updateAppearance() {
        let titleText = isRecording ? "Type Shortcut" : shortcut.displayString
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        attributedTitle = NSAttributedString(
            string: titleText,
            attributes: [.font: font]
        )
    }
}
