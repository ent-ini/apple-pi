import AppKit
import Foundation
import Testing
@testable import ApplePi

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

@Test func windowAppearanceSettingsClampAlphaToAvoidInvisibleWindow() {
    var appearance = AppAppearance()
    appearance.windowOpacity = 0.10
    let settings = appearance.windowAppearanceSettings
    #expect(settings.alpha >= 0.55)
}

@Test func windowAppearanceSettingsClampAlphaToAtMostOne() {
    var appearance = AppAppearance()
    appearance.windowOpacity = 1.5
    let settings = appearance.windowAppearanceSettings
    #expect(settings.alpha <= 1.0)
}

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
