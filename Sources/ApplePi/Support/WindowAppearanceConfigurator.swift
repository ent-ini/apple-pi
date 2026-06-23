import AppKit
import SwiftUI

/// Pure, side-effect-free description of how the main window should look.
/// Splitting the decision (this struct) from the application
/// (`AppAppearanceWindowApplier`) keeps the decision logic unit-testable
/// without having to construct a real `NSWindow`.
struct WindowAppearanceSettings: Equatable, Sendable {
    var alpha: CGFloat
    var isOpaque: Bool
    var titlebarAppearsTransparent: Bool
    var usesFullSizeContentView: Bool
    var toolbarStyle: NSWindow.ToolbarStyle
    var isMovableByWindowBackground: Bool
}

extension AppAppearance {
    /// Snapshot of the appearance that the main window should reflect.
    /// Pure function of the appearance struct; the applier reads this
    /// and copies the values onto a live `NSWindow`.
    var windowAppearanceSettings: WindowAppearanceSettings {
        // The window-level alpha is clamped to a sane lower bound so the
        // user can never end up with a fully invisible window. The
        // side-panel surfaces have their own per-pane opacity on top.
        let clampedOpacity = min(max(effectiveWindowOpacity, 0.55), 1.0)
        return WindowAppearanceSettings(
            alpha: CGFloat(clampedOpacity),
            isOpaque: false,
            titlebarAppearsTransparent: useTransparentTitlebar,
            usesFullSizeContentView: useTransparentTitlebar,
            toolbarStyle: .unified,
            isMovableByWindowBackground: false
        )
    }
}

/// Side-effecting applier that copies a `WindowAppearanceSettings` value
/// onto a live `NSWindow`. Isolated from the decision logic so the
/// decision is unit-testable in headless environments.
enum AppAppearanceWindowApplier {
    static func apply(_ settings: WindowAppearanceSettings, to window: NSWindow) {
        window.alphaValue = settings.alpha
        window.isOpaque = settings.isOpaque
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = settings.titlebarAppearsTransparent
        if settings.usesFullSizeContentView {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.toolbarStyle = settings.toolbarStyle
        window.isMovableByWindowBackground = settings.isMovableByWindowBackground
    }

    static func apply(_ appearance: AppAppearance, to window: NSWindow) {
        apply(appearance.windowAppearanceSettings, to: window)
    }
}

struct WindowAppearanceConfigurator: NSViewRepresentable {
    let appearance: AppAppearance

    func makeNSView(context: Context) -> WindowAppearanceHostView {
        let view = WindowAppearanceHostView(frame: .zero)
        view.applyAppearance = { window in
            guard let window else { return }
            AppAppearanceWindowApplier.apply(appearance, to: window)
        }
        view.applyAppearanceToCurrentWindow()
        return view
    }

    func updateNSView(_ nsView: WindowAppearanceHostView, context: Context) {
        nsView.applyAppearance = { window in
            guard let window else { return }
            AppAppearanceWindowApplier.apply(appearance, to: window)
        }
        nsView.applyAppearanceToCurrentWindow()
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
