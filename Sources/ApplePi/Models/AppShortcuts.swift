import AppKit
import SwiftUI

enum AppShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case newSession
    case newTemporarySession
    case newSessionInFolder
    case findSessions
    case refreshSessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: "New Session"
        case .newTemporarySession: "New Temporary Session"
        case .newSessionInFolder: "New Session in Folder"
        case .findSessions: "Find Sessions"
        case .refreshSessions: "Refresh Sessions"
        }
    }

    var defaultShortcut: AppShortcut {
        switch self {
        case .newSession:
            AppShortcut(key: .character("n"), modifiers: .command)
        case .newTemporarySession:
            AppShortcut(key: .character("n"), modifiers: [.command, .shift])
        case .newSessionInFolder:
            AppShortcut(key: .character("n"), modifiers: [.command, .option])
        case .findSessions:
            AppShortcut(key: .character("f"), modifiers: .command)
        case .refreshSessions:
            AppShortcut(key: .character("r"), modifiers: .command)
        }
    }
}

struct AppShortcutPreferences: Codable, Equatable, Sendable {
    var customBindings: [AppShortcutAction: AppShortcut] = [:]

    func binding(for action: AppShortcutAction) -> AppShortcut {
        customBindings[action] ?? action.defaultShortcut
    }

    mutating func set(_ shortcut: AppShortcut, for action: AppShortcutAction) {
        let previousShortcut = binding(for: action)
        if let conflictingAction = AppShortcutAction.allCases.first(where: { $0 != action && binding(for: $0) == shortcut }) {
            apply(previousShortcut, to: conflictingAction)
        }
        apply(shortcut, to: action)
    }

    private mutating func apply(_ shortcut: AppShortcut, to action: AppShortcutAction) {
        if shortcut == action.defaultShortcut {
            customBindings.removeValue(forKey: action)
        } else {
            customBindings[action] = shortcut
        }
    }
}

struct AppShortcut: Codable, Equatable, Hashable, Sendable {
    var key: ShortcutKey
    var modifiers: ShortcutModifiers

    init(key: ShortcutKey, modifiers: ShortcutModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(capturing event: NSEvent) {
        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard !modifiers.isEmpty else { return nil }

        if let specialKey = SpecialShortcutKey(event: event) {
            self.init(key: .special(specialKey), modifiers: modifiers)
            return
        }

        guard let rawCharacters = event.charactersIgnoringModifiers,
              let keyCharacter = ShortcutKey.character(from: rawCharacters) else {
            return nil
        }

        self.init(key: .character(keyCharacter), modifiers: modifiers)
    }

    var keyEquivalent: KeyEquivalent {
        key.keyEquivalent
    }

    var eventModifiers: EventModifiers {
        modifiers.eventModifiers
    }

    var displayString: String {
        modifiers.displayString + key.displayString
    }
}

enum ShortcutKey: Codable, Equatable, Hashable, Sendable {
    case character(String)
    case special(SpecialShortcutKey)

    fileprivate static func character(from rawCharacters: String) -> String? {
        let scalars = rawCharacters.unicodeScalars.filter { $0.properties.generalCategory != .control }
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        return String(Character(String(scalar))).lowercased()
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let value):
            return KeyEquivalent(Character(value))
        case .special(let value):
            return value.keyEquivalent
        }
    }

    var displayString: String {
        switch self {
        case .character(let value):
            value.uppercased()
        case .special(let value):
            value.displayString
        }
    }
}

enum SpecialShortcutKey: String, Codable, CaseIterable, Hashable, Sendable {
    case returnKey
    case delete
    case escape
    case space
    case tab

    init?(event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            self = .returnKey
        case 48:
            self = .tab
        case 49:
            self = .space
        case 51, 117:
            self = .delete
        case 53:
            self = .escape
        default:
            return nil
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .returnKey:
            .return
        case .delete:
            .delete
        case .escape:
            .escape
        case .space:
            .space
        case .tab:
            .tab
        }
    }

    var displayString: String {
        switch self {
        case .returnKey:
            "↩"
        case .delete:
            "⌫"
        case .escape:
            "⎋"
        case .space:
            "Space"
        case .tab:
            "⇥"
        }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.command) { value.insert(.command) }
        if normalized.contains(.option) { value.insert(.option) }
        if normalized.contains(.shift) { value.insert(.shift) }
        if normalized.contains(.control) { value.insert(.control) }
        self = value
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.command) { modifiers.insert(.command) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    var displayString: String {
        var pieces: [String] = []
        if contains(.control) { pieces.append("⌃") }
        if contains(.option) { pieces.append("⌥") }
        if contains(.shift) { pieces.append("⇧") }
        if contains(.command) { pieces.append("⌘") }
        return pieces.joined()
    }
}
