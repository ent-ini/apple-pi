import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Outcome of a notification delivery attempt. Exposed to the settings
/// view so the user can see why a test banner may not have appeared.
enum TerminalNotificationDeliveryResult: Sendable {
    case delivered
    case disabled
    case suppressedInForeground
    case denied
    case failed
}

/// Thin wrapper around `UNUserNotificationCenter` that bridges the
/// stored `TerminalNotificationPreferences` (chat session notifications)
/// to the macOS notification UI. Replaces the old OSC 777 path that the
/// terminal host used to drive, since we no longer run a terminal.
@MainActor
final class NativeNotificationPresenter {
    static let shared = NativeNotificationPresenter()

    private let center = UNUserNotificationCenter.current()

    /// Ask the system for notification permission up front. Safe to call
    /// repeatedly; the system will only prompt the user once.
    @discardableResult
    func prepareAuthorization(for preferences: TerminalNotificationPreferences) async -> Bool {
        guard preferences.isEnabled else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Present a single notification immediately. Honours the user's
    /// `presentation` and `allowsForegroundNotifications` settings.
    func present(
        title: String,
        body: String,
        preferences: TerminalNotificationPreferences
    ) async -> TerminalNotificationDeliveryResult {
        guard preferences.isEnabled else { return .disabled }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return .denied
        case .notDetermined:
            let granted = await prepareAuthorization(for: preferences)
            guard granted else { return .denied }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return .failed
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if preferences.presentation.usesSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            return .delivered
        } catch {
            return .failed
        }
    }
}
