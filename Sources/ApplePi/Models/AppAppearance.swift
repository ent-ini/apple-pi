import Foundation
import SwiftUI

struct AppAppearance: Codable, Equatable {
    var windowOpacity: Double = 0.94
    var sidebarOpacity: Double = 0.52
    var listOpacity: Double = 0.64
    var chromeOpacity: Double = 0.76
    var chatSurfaceOpacity: Double = 0.92
    var accentColorName: AccentColorName = .yellow
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
        accentColorName = try container.decodeIfPresent(AccentColorName.self, forKey: .accentColorName) ?? .yellow
        colorScheme = try container.decodeIfPresent(AppColorSchemePreference.self, forKey: .colorScheme) ?? .system
        reduceTransparency = try container.decodeIfPresent(Bool.self, forKey: .reduceTransparency) ?? false
        useTransparentTitlebar = try container.decodeIfPresent(Bool.self, forKey: .useTransparentTitlebar) ?? true
        emptyChatMessage = try container.decodeIfPresent(String.self, forKey: .emptyChatMessage)
            ?? container.decodeIfPresent(String.self, forKey: .emptyTerminalMessage)
            ?? "Hi"
        notifications = try container.decodeIfPresent(TerminalNotificationPreferences.self, forKey: .notifications) ?? TerminalNotificationPreferences()
    }

    var accentColor: Color {
        accentColorName.color
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

    var title: String {
        switch self {
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .green: "Green"
        case .graphite: "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .yellow: Color(red: 0.98, green: 0.78, blue: 0.23)
        case .blue: Color(red: 0.42, green: 0.63, blue: 1.0)
        case .green: Color(red: 0.42, green: 0.82, blue: 0.55)
        case .graphite: Color(red: 0.66, green: 0.68, blue: 0.72)
        }
    }
}
