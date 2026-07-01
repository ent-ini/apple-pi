import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

@Test func windowAppearanceSettingsHonorTransparentTitlebarToggle() {
    var appearance = AppAppearance()
    appearance.useTransparentTitlebar = true
    let transparent = appearance.windowAppearanceSettings
    #expect(transparent.titlebarAppearsTransparent)
    #expect(transparent.usesFullSizeContentView)

    appearance.useTransparentTitlebar = false
    let opaque = appearance.windowAppearanceSettings
    #expect(opaque.titlebarAppearsTransparent == false)
    #expect(opaque.usesFullSizeContentView == false)
}

@Test func windowAppearanceSettingsDefaultToTransparentTitlebar() {
    let appearance = AppAppearance()
    let settings = appearance.windowAppearanceSettings
    #expect(settings.titlebarAppearsTransparent)
    #expect(settings.usesFullSizeContentView)
}

@Test func windowAppearanceSettingsUseFullyOpaqueWindowAlpha() {
    let appearance = AppAppearance()
    let settings = appearance.windowAppearanceSettings
    #expect(settings.alpha == 1.0)
}

@MainActor
@Test func windowAppearanceSettingsApplyToWindowMutatesExpectedProperties() {
    let appearance = AppAppearance()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )

    AppAppearanceWindowApplier.apply(appearance, to: window)

    #expect(window.alphaValue > 0.55)
    #expect(window.isOpaque == false)
    #expect(window.titlebarAppearsTransparent == appearance.useTransparentTitlebar)
    #expect(window.styleMask.contains(.fullSizeContentView) == appearance.useTransparentTitlebar)
    #expect(window.isMovableByWindowBackground == false)
}

@MainActor
@Test func windowAppearanceSettingsApplyToWindowTogglesFullSizeContentView() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )

    var transparentAppearance = AppAppearance()
    transparentAppearance.useTransparentTitlebar = true
    AppAppearanceWindowApplier.apply(transparentAppearance, to: window)
    #expect(window.styleMask.contains(.fullSizeContentView))

    var opaqueAppearance = AppAppearance()
    opaqueAppearance.useTransparentTitlebar = false
    AppAppearanceWindowApplier.apply(opaqueAppearance, to: window)
    #expect(window.styleMask.contains(.fullSizeContentView) == false)
}

@MainActor
@Test func windowAppearanceSettingsApplyTopBarColorToWindowBackground() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )

    var appearance = AppAppearance()
    appearance.colorScheme = .light
    let expectedColor = Color(red: 0.12, green: 0.34, blue: 0.56)
    appearance.setTopBarBackgroundColor(expectedColor)

    AppAppearanceWindowApplier.apply(appearance, to: window)

    let actualColor = window.backgroundColor.usingColorSpace(.sRGB)
    let expectedNSColor = NSColor(expectedColor).usingColorSpace(.sRGB)
    #expect(actualColor?.isApproximatelyEqual(to: expectedNSColor) == true)
}

private extension NSColor {
    func isApproximatelyEqual(to other: NSColor?, tolerance: CGFloat = 0.01) -> Bool {
        guard let other,
              let lhs = usingColorSpace(.sRGB),
              let rhs = other.usingColorSpace(.sRGB) else {
            return false
        }

        return abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }
}
