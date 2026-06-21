import AppKit
import SwiftUI

struct WindowAppearanceConfigurator: NSViewRepresentable {
    let appearance: AppAppearance

    func makeNSView(context: Context) -> WindowAppearanceHostView {
        let view = WindowAppearanceHostView(frame: .zero)
        view.applyAppearance = { window in
            apply(to: window)
        }
        view.applyAppearanceToCurrentWindow()
        return view
    }

    func updateNSView(_ nsView: WindowAppearanceHostView, context: Context) {
        nsView.applyAppearance = { window in
            apply(to: window)
        }
        nsView.applyAppearanceToCurrentWindow()
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.alphaValue = CGFloat(min(max(appearance.effectiveWindowOpacity, 0.55), 1.0))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = appearance.useTransparentTitlebar
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
    }
}

final class WindowAppearanceHostView: NSView {
    var applyAppearance: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearanceToCurrentWindow()
    }

    func applyAppearanceToCurrentWindow() {
        applyAppearance?(window)
    }
}
