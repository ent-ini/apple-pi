import SwiftUI
import AppKit
@preconcurrency import UserNotifications

@main
struct ApplePiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = PiAppState()

    var body: some Scene {
        WindowGroup("pi-app", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 260, minHeight: 180)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.shutdownForTermination()
                }
        }
        .commands {
            ApplePiCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
                .overlay(alignment: .topLeading) {
                    // Mirror the main window's appearance so the titlebar
                    // toggle and opacity apply here too. The overlay is
                    // zero-sized and non-interactive.
                    WindowAppearanceConfigurator(appearance: appState.appearance)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let preferences = ChatNotificationPreferenceReader.current()
        guard preferences.isEnabled, preferences.allowsForegroundNotifications else { return [] }

        var options: UNNotificationPresentationOptions = []
        if preferences.presentation.usesBanner {
            options.insert(.banner)
        }
        if preferences.presentation.usesSound {
            options.insert(.sound)
        }
        return options
    }
}

enum ChatNotificationPreferenceReader {
    private static let appearanceDefaultsKey = "ApplePi.appearance"

    static func current() -> TerminalNotificationPreferences {
        let defaults = Foundation.UserDefaults(suiteName: nil) ?? Foundation.UserDefaults()
        guard let data = defaults.data(forKey: appearanceDefaultsKey),
              let appearance = try? JSONDecoder().decode(AppAppearance.self, from: data) else {
            return TerminalNotificationPreferences()
        }
        return appearance.notifications
    }
}

struct ApplePiCommands: Commands {
    @ObservedObject var appState: PiAppState

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Find Sessions") {
                appState.requestSessionSearchFocus()
            }
            .keyboardShortcut(shortcut(for: .findSessions).keyEquivalent, modifiers: shortcut(for: .findSessions).eventModifiers)
        }

        CommandMenu("Pi") {
            Button("New Session") {
                appState.openNewSessionInCurrentFolder()
            }
            .keyboardShortcut(shortcut(for: .newSession).keyEquivalent, modifiers: shortcut(for: .newSession).eventModifiers)

            Button("New Temporary Session") {
                appState.openTemporarySessionInCurrentFolder()
            }
            .keyboardShortcut(shortcut(for: .newTemporarySession).keyEquivalent, modifiers: shortcut(for: .newTemporarySession).eventModifiers)

            Button("New Session in Folder...") {
                appState.presentNewSessionInFolder()
            }
            .keyboardShortcut(shortcut(for: .newSessionInFolder).keyEquivalent, modifiers: shortcut(for: .newSessionInFolder).eventModifiers)

            Divider()

            Button("Refresh Sessions") {
                appState.refreshCatalog()
            }
            .keyboardShortcut(shortcut(for: .refreshSessions).keyEquivalent, modifiers: shortcut(for: .refreshSessions).eventModifiers)
        }
    }

    private func shortcut(for action: AppShortcutAction) -> AppShortcut {
        appState.shortcut(for: action)
    }
}
