import SwiftUI
@preconcurrency import UserNotifications

@main
struct ApplePiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = PiAppState()

    var body: some Scene {
        WindowGroup("Apple Pi", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 260, minHeight: 180)
        }
        .commands {
            ApplePiCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
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
        let preferences = TerminalNotificationPreferenceReader.current()
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

enum TerminalNotificationPreferenceReader {
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
        CommandMenu("Pi") {
            Button("New Session") {
                appState.openNewSessionInCurrentFolder()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Temporary Session") {
                appState.openTemporarySessionInCurrentFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Session in Folder...") {
                appState.presentNewSessionInFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("Refresh Sessions") {
                appState.refreshCatalog()
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
    }
}
