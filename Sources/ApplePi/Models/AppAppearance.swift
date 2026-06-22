import AppKit
import Foundation
import SwiftUI

struct AppAppearance: Codable, Equatable {
    var windowOpacity: Double = 0.94
    var sidebarOpacity: Double = 0.52
    var listOpacity: Double = 0.64
    var chromeOpacity: Double = 0.76
    var chatSurfaceOpacity: Double = 0.92
    var accentColorValue: CodableAccentColor = .yellow
    var colorScheme: AppColorSchemePreference = .system
    var reduceTransparency: Bool = false
    var useTransparentTitlebar: Bool = true
    var emptyChatMessage: String = "Hi"
    var notifications: TerminalNotificationPreferences = TerminalNotificationPreferences()

    init() {}

    // Explicit CodingKeys: we keep `terminalOpacity` and
    // `emptyTerminalMessage` around so a 0.x user's saved settings still
    // decode after the rename. The current code only writes the new
    // names, so the legacy keys are only consulted on read.
    enum CodingKeys: String, CodingKey {
        case windowOpacity
        case sidebarOpacity
        case listOpacity
        case chromeOpacity
        case chatSurfaceOpacity
        case terminalOpacity
        case accentColorValue
        case accentColorName
        case colorScheme
        case reduceTransparency
        case useTransparentTitlebar
        case emptyChatMessage
        case emptyTerminalMessage
        case notifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowOpacity = try container.decodeIfPresent(Double.self, forKey: .windowOpacity) ?? 0.94
        sidebarOpacity = try container.decodeIfPresent(Double.self, forKey: .sidebarOpacity) ?? 0.52
        listOpacity = try container.decodeIfPresent(Double.self, forKey: .listOpacity) ?? 0.64
        chromeOpacity = try container.decodeIfPresent(Double.self, forKey: .chromeOpacity) ?? 0.76
        // Backward compatibility: accept the old `terminalOpacity` key from
        // the previous app version so users on 0.x settings do not lose
        // their configured transparency when upgrading to the chat build.
        chatSurfaceOpacity = try container.decodeIfPresent(Double.self, forKey: .chatSurfaceOpacity)
            ?? container.decodeIfPresent(Double.self, forKey: .terminalOpacity)
            ?? 0.92
        accentColorValue = try container.decodeIfPresent(CodableAccentColor.self, forKey: .accentColorValue)
            ?? (try container.decodeIfPresent(AccentColorName.self, forKey: .accentColorName).map(CodableAccentColor.init))
            ?? .yellow
        colorScheme = try container.decodeIfPresent(AppColorSchemePreference.self, forKey: .colorScheme) ?? .system
        reduceTransparency = try container.decodeIfPresent(Bool.self, forKey: .reduceTransparency) ?? false
        useTransparentTitlebar = try container.decodeIfPresent(Bool.self, forKey: .useTransparentTitlebar) ?? true
        emptyChatMessage = try container.decodeIfPresent(String.self, forKey: .emptyChatMessage)
            ?? container.decodeIfPresent(String.self, forKey: .emptyTerminalMessage)
            ?? "Hi"
        notifications = try container.decodeIfPresent(TerminalNotificationPreferences.self, forKey: .notifications) ?? TerminalNotificationPreferences()
    }

    // We have to write the encoder by hand because `CodingKeys` lists two
    // legacy cases (`terminalOpacity`, `emptyTerminalMessage`) that do not
    // correspond to any stored property any more. Without this method
    // Swift refuses to synthesise `Encodable`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowOpacity, forKey: .windowOpacity)
        try container.encode(sidebarOpacity, forKey: .sidebarOpacity)
        try container.encode(listOpacity, forKey: .listOpacity)
        try container.encode(chromeOpacity, forKey: .chromeOpacity)
        try container.encode(chatSurfaceOpacity, forKey: .chatSurfaceOpacity)
        // terminalOpacity / emptyTerminalMessage are legacy read-only
        // fields; new encodes always write the renamed properties.
        try container.encode(accentColorValue, forKey: .accentColorValue)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(reduceTransparency, forKey: .reduceTransparency)
        try container.encode(useTransparentTitlebar, forKey: .useTransparentTitlebar)
        try container.encode(emptyChatMessage, forKey: .emptyChatMessage)
        try container.encode(notifications, forKey: .notifications)
    }

    var accentColor: Color {
        accentColorValue.color
    }

    var accentForegroundColor: Color {
        accentColorValue.isDark ? .white : .black
    }

    mutating func setAccentColor(_ color: Color) {
        accentColorValue = CodableAccentColor(color)
    }

    var resolvedEmptyChatMessage: String {
        let trimmedMessage = emptyChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? "Hi" : trimmedMessage
    }

    var effectiveWindowOpacity: Double {
        reduceTransparency ? 1.0 : windowOpacity
    }

    var effectiveSidebarOpacity: Double {
        reduceTransparency ? 0.92 : sidebarOpacity
    }

    var effectiveListOpacity: Double {
        reduceTransparency ? 0.92 : listOpacity
    }

    var effectiveChromeOpacity: Double {
        reduceTransparency ? 0.94 : chromeOpacity
    }

    var effectiveChatOpacity: Double {
        reduceTransparency ? 1.0 : chatSurfaceOpacity
    }
}

struct TerminalNotificationPreferences: Codable, Equatable, Sendable {
    var isEnabled: Bool = true
    var presentation: TerminalNotificationPresentation = .bannerAndSound
    var allowsForegroundNotifications: Bool = true
}

enum TerminalNotificationPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case bannerOnly
    case soundOnly
    case bannerAndSound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bannerOnly: "Banner"
        case .soundOnly: "Sound"
        case .bannerAndSound: "Banner + Sound"
        }
    }

    var usesBanner: Bool {
        self != .soundOnly
    }

    var usesSound: Bool {
        self != .bannerOnly
    }

    var usesSystemNotification: Bool {
        self != .soundOnly
    }
}

enum AppColorSchemePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentColorName: String, Codable, CaseIterable, Identifiable {
    case yellow
    case blue
    case green
    case graphite

    var id: String { rawValue }

    var colorValue: CodableAccentColor {
        switch self {
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        case .graphite: .graphite
        }
    }
}

struct CodableAccentColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ preset: AccentColorName) {
        self = preset.colorValue
    }

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemYellow
        self.red = Double(nsColor.redComponent)
        self.green = Double(nsColor.greenComponent)
        self.blue = Double(nsColor.blueComponent)
        self.alpha = Double(nsColor.alphaComponent)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var isDark: Bool {
        relativeLuminance < 0.58
    }

    private var relativeLuminance: Double {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    static let yellow = CodableAccentColor(red: 0.98, green: 0.78, blue: 0.23)
    static let blue = CodableAccentColor(red: 0.42, green: 0.63, blue: 1.0)
    static let green = CodableAccentColor(red: 0.42, green: 0.82, blue: 0.55)
    static let graphite = CodableAccentColor(red: 0.66, green: 0.68, blue: 0.72)
}
