import AppKit
import Foundation
@preconcurrency import SwiftTerm

struct TerminalThemeAppearance: Equatable {
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let ansiPalette: [NSColor]

    static let defaultValue = TerminalThemeAppearance(
        backgroundColor: NSColor(red: 0.055, green: 0.067, blue: 0.082, alpha: 1),
        foregroundColor: NSColor(red: 0.89, green: 0.93, blue: 0.96, alpha: 1),
        ansiPalette: [
            NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1),
            NSColor(red: 0.91, green: 0.31, blue: 0.36, alpha: 1),
            NSColor(red: 0.31, green: 0.78, blue: 0.55, alpha: 1),
            NSColor(red: 0.94, green: 0.70, blue: 0.32, alpha: 1),
            NSColor(red: 0.35, green: 0.58, blue: 0.93, alpha: 1),
            NSColor(red: 0.77, green: 0.45, blue: 0.91, alpha: 1),
            NSColor(red: 0.32, green: 0.76, blue: 0.82, alpha: 1),
            NSColor(red: 0.82, green: 0.86, blue: 0.90, alpha: 1),
            NSColor(red: 0.37, green: 0.41, blue: 0.47, alpha: 1),
            NSColor(red: 0.98, green: 0.47, blue: 0.50, alpha: 1),
            NSColor(red: 0.47, green: 0.88, blue: 0.64, alpha: 1),
            NSColor(red: 0.98, green: 0.78, blue: 0.43, alpha: 1),
            NSColor(red: 0.50, green: 0.67, blue: 0.98, alpha: 1),
            NSColor(red: 0.86, green: 0.56, blue: 0.96, alpha: 1),
            NSColor(red: 0.45, green: 0.86, blue: 0.90, alpha: 1),
            NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        ]
    )
}

struct TerminalPreferences: Codable, Equatable {
    var themeName: TerminalThemeName = .midnight
    var fontFamily: TerminalFontFamily = .sfMono
    var fontSize: Double = TerminalFontPreference.defaultSize
    var scrollbackLines: TerminalScrollbackPreference = .medium
    var optionAsMetaKey: Bool = true
    var allowMouseReporting: Bool = true
    var linkMode: TerminalLinkMode = .commandClick
    var useBrightColors: Bool = true
    var backspaceSendsControlH: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themeName = try container.decodeIfPresent(TerminalThemeName.self, forKey: .themeName) ?? .midnight
        fontFamily = try container.decodeIfPresent(TerminalFontFamily.self, forKey: .fontFamily) ?? .sfMono
        fontSize = TerminalFontPreference.clamped(
            try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? TerminalFontPreference.defaultSize
        )
        scrollbackLines = try container.decodeIfPresent(TerminalScrollbackPreference.self, forKey: .scrollbackLines) ?? .medium
        optionAsMetaKey = try container.decodeIfPresent(Bool.self, forKey: .optionAsMetaKey) ?? true
        allowMouseReporting = try container.decodeIfPresent(Bool.self, forKey: .allowMouseReporting) ?? true
        linkMode = try container.decodeIfPresent(TerminalLinkMode.self, forKey: .linkMode) ?? .commandClick
        useBrightColors = try container.decodeIfPresent(Bool.self, forKey: .useBrightColors) ?? true
        backspaceSendsControlH = try container.decodeIfPresent(Bool.self, forKey: .backspaceSendsControlH) ?? false
    }

    var theme: TerminalThemeAppearance {
        themeName.appearance
    }
}

enum TerminalThemeName: String, Codable, CaseIterable, Identifiable {
    case midnight
    case graphite
    case highContrast
    case paper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .highContrast: "High Contrast"
        case .paper: "Paper"
        }
    }

    var appearance: TerminalThemeAppearance {
        switch self {
        case .midnight:
            TerminalThemeAppearance.defaultValue
        case .graphite:
            TerminalThemeAppearance(
                backgroundColor: NSColor(red: 0.11, green: 0.115, blue: 0.125, alpha: 1),
                foregroundColor: NSColor(red: 0.88, green: 0.89, blue: 0.90, alpha: 1),
                ansiPalette: [
                    NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1),
                    NSColor(red: 0.84, green: 0.34, blue: 0.36, alpha: 1),
                    NSColor(red: 0.39, green: 0.72, blue: 0.48, alpha: 1),
                    NSColor(red: 0.82, green: 0.66, blue: 0.36, alpha: 1),
                    NSColor(red: 0.42, green: 0.57, blue: 0.82, alpha: 1),
                    NSColor(red: 0.70, green: 0.47, blue: 0.78, alpha: 1),
                    NSColor(red: 0.38, green: 0.68, blue: 0.72, alpha: 1),
                    NSColor(red: 0.78, green: 0.80, blue: 0.82, alpha: 1),
                    NSColor(red: 0.36, green: 0.37, blue: 0.40, alpha: 1),
                    NSColor(red: 0.94, green: 0.46, blue: 0.48, alpha: 1),
                    NSColor(red: 0.52, green: 0.82, blue: 0.58, alpha: 1),
                    NSColor(red: 0.92, green: 0.76, blue: 0.43, alpha: 1),
                    NSColor(red: 0.55, green: 0.68, blue: 0.94, alpha: 1),
                    NSColor(red: 0.80, green: 0.58, blue: 0.90, alpha: 1),
                    NSColor(red: 0.49, green: 0.80, blue: 0.84, alpha: 1),
                    NSColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
                ]
            )
        case .highContrast:
            TerminalThemeAppearance(
                backgroundColor: .black,
                foregroundColor: .white,
                ansiPalette: [
                    .black, .systemRed, .systemGreen, .systemYellow,
                    .systemBlue, .systemPurple, .systemCyan, .white,
                    .darkGray, .systemRed, .systemGreen, .systemYellow,
                    .systemBlue, .systemPurple, .systemCyan, .white
                ]
            )
        case .paper:
            TerminalThemeAppearance(
                backgroundColor: NSColor(red: 0.94, green: 0.93, blue: 0.90, alpha: 1),
                foregroundColor: NSColor(red: 0.10, green: 0.105, blue: 0.115, alpha: 1),
                ansiPalette: [
                    NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1),
                    NSColor(red: 0.70, green: 0.18, blue: 0.20, alpha: 1),
                    NSColor(red: 0.16, green: 0.50, blue: 0.28, alpha: 1),
                    NSColor(red: 0.64, green: 0.43, blue: 0.12, alpha: 1),
                    NSColor(red: 0.18, green: 0.36, blue: 0.68, alpha: 1),
                    NSColor(red: 0.50, green: 0.26, blue: 0.62, alpha: 1),
                    NSColor(red: 0.12, green: 0.48, blue: 0.54, alpha: 1),
                    NSColor(red: 0.68, green: 0.68, blue: 0.66, alpha: 1),
                    NSColor(red: 0.40, green: 0.40, blue: 0.39, alpha: 1),
                    NSColor(red: 0.84, green: 0.26, blue: 0.28, alpha: 1),
                    NSColor(red: 0.23, green: 0.62, blue: 0.36, alpha: 1),
                    NSColor(red: 0.76, green: 0.54, blue: 0.19, alpha: 1),
                    NSColor(red: 0.30, green: 0.48, blue: 0.78, alpha: 1),
                    NSColor(red: 0.62, green: 0.38, blue: 0.74, alpha: 1),
                    NSColor(red: 0.20, green: 0.60, blue: 0.66, alpha: 1),
                    NSColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)
                ]
            )
        }
    }
}

enum TerminalFontFamily: String, Codable, CaseIterable, Identifiable {
    case sfMono
    case menlo
    case monaco

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .monaco: "Monaco"
        }
    }

    func font(size: Double) -> NSFont {
        let clampedSize = CGFloat(TerminalFontPreference.clamped(size))
        switch self {
        case .sfMono:
            return NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo", size: clampedSize) ?? NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
        case .monaco:
            return NSFont(name: "Monaco", size: clampedSize) ?? NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
        }
    }
}

enum TerminalScrollbackPreference: Int, Codable, CaseIterable, Identifiable {
    case compact = 500
    case medium = 2_000
    case deep = 10_000
    case veryDeep = 50_000

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .compact: "500 lines"
        case .medium: "2,000 lines"
        case .deep: "10,000 lines"
        case .veryDeep: "50,000 lines"
        }
    }
}

enum TerminalLinkMode: String, Codable, CaseIterable, Identifiable {
    case commandClick
    case explicitOnly
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandClick: "Command-click URLs"
        case .explicitOnly: "App-provided links only"
        case .disabled: "Off"
        }
    }

    var reporting: LinkReporting {
        switch self {
        case .commandClick: .implicit
        case .explicitOnly: .explicit
        case .disabled: .none
        }
    }

    var highlightMode: LinkHighlightMode {
        switch self {
        case .commandClick, .explicitOnly: .hoverWithModifier
        case .disabled: .hoverWithModifier
        }
    }
}

enum TerminalFontPreference {
    static let minimumSize = 11.0
    static let maximumSize = 22.0
    static let defaultSize = 13.5

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimumSize), maximumSize)
    }
}
