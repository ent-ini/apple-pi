import AppKit
import Foundation
@preconcurrency import UserNotifications
@preconcurrency import SwiftTerm

@MainActor
final class TerminalViewHost: NSObject, LocalProcessTerminalViewDelegate {
    private let hostView = TerminalHostView()
    private var startedLaunchToken: UUID?
    private var scheduledLaunchToken: UUID?
    private var appliedPreferences: TerminalPreferences?
    private var notificationPreferences = TerminalNotificationPreferences()
    private var lastNotification: (title: String, body: String, date: Date)?
    private var onProcessStart: (() -> Void)?
    private var onTitleChange: ((String) -> Void)?
    private var onDirectoryChange: ((String?) -> Void)?
    private var onProcessExit: ((Int32?) -> Void)?

    override init() {
        super.init()
        hostView.terminalView.processDelegate = self
    }

    func setEventHandlers(
        onProcessStart: @escaping () -> Void,
        onTitleChange: @escaping (String) -> Void,
        onDirectoryChange: @escaping (String?) -> Void,
        onProcessExit: @escaping (Int32?) -> Void
    ) {
        self.onProcessStart = onProcessStart
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onProcessExit = onProcessExit
    }

    func mount(
        in container: TerminalMountContainerView,
        request: TerminalProcessRequest,
        launchToken: UUID,
        preferences: TerminalPreferences,
        notificationPreferences: TerminalNotificationPreferences,
        isActive: Bool
    ) {
        container.mount(hostView)
        self.notificationPreferences = notificationPreferences
        applyPreferences(preferences)
        setActive(isActive)
        scheduleStartIfNeeded(request: request, launchToken: launchToken)
    }

    func unmount(from container: TerminalMountContainerView) {
        container.unmountHostedView()
    }

    nonisolated func terminate() {
        performSelector(onMainThread: #selector(terminateOnMainThread), with: nil, waitUntilDone: false)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in self?.onTitleChange?(title) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in self?.onDirectoryChange?(directory) }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.onProcessExit?(exitCode) }
    }

    private func scheduleStartIfNeeded(request: TerminalProcessRequest, launchToken: UUID) {
        guard startedLaunchToken != launchToken else { return }
        guard scheduledLaunchToken != launchToken else { return }
        scheduledLaunchToken = launchToken

        Task { @MainActor [weak self] in
            self?.startIfNeeded(request: request, launchToken: launchToken)
        }
    }

    private func startIfNeeded(request: TerminalProcessRequest, launchToken: UUID) {
        scheduledLaunchToken = nil
        guard startedLaunchToken != launchToken else { return }
        startedLaunchToken = launchToken

        hostView.terminalView.terminal.registerOscHandler(code: 777) { [weak self] payload in
            guard let notification = OSC777NotificationPayload(bytes: payload) else { return }
            Task { @MainActor [weak self] in
                self?.presentNotification(
                    title: notification.title,
                    body: notification.body
                )
            }
        }

        hostView.terminalView.startProcess(
            executable: request.executable,
            args: request.arguments,
            environment: request.environment,
            execName: request.execName,
            currentDirectory: request.workingDirectory
        )
        onProcessStart?()
    }

    @discardableResult
    private func presentNotification(title: String, body: String) -> Bool {
        guard notificationPreferences.isEnabled else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else { return false }

        let now = Date()
        if let lastNotification,
           lastNotification.title == title,
           lastNotification.body == body,
           now.timeIntervalSince(lastNotification.date) < 1 {
            return true
        }
        lastNotification = (title, body, now)

        let preferences = notificationPreferences
        Task { @MainActor in
            _ = await NativeNotificationPresenter.shared.present(
                title: title,
                body: body,
                preferences: preferences
            )
        }
        return true
    }

    private func applyPreferences(_ preferences: TerminalPreferences) {
        guard appliedPreferences != preferences else { return }
        appliedPreferences = preferences
        hostView.apply(preferences: preferences)
    }

    private func setActive(_ isActive: Bool) {
        hostView.isHidden = !isActive
        if isActive {
            hostView.window?.makeFirstResponder(hostView.terminalView)
        }
    }

    @objc
    private func terminateOnMainThread() {
        scheduledLaunchToken = nil
        startedLaunchToken = nil
        hostView.terminalView.terminate()
    }
}

enum TerminalNotificationDeliveryResult: Equatable, Sendable {
    case delivered
    case disabled
    case suppressedInForeground
    case denied
    case failed
}

@MainActor
final class NativeNotificationPresenter {
    static let shared = NativeNotificationPresenter()

    func prepareAuthorization(for presentation: TerminalNotificationPresentation) async -> Bool {
        guard presentation.usesSystemNotification else { return true }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func present(
        title: String,
        body: String,
        preferences: TerminalNotificationPreferences
    ) async -> TerminalNotificationDeliveryResult {
        guard preferences.isEnabled else { return .disabled }
        let isAppActive = NSApp.isActive
        guard preferences.allowsForegroundNotifications || !isAppActive else {
            return .suppressedInForeground
        }

        if preferences.presentation == .soundOnly {
            NSSound.beep()
            return .delivered
        }

        guard await prepareAuthorization(for: preferences.presentation) else {
            return .denied
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
            try await UNUserNotificationCenter.current().add(request)
            return .delivered
        } catch {
            return .failed
        }
    }
}

final class TerminalMountContainerView: NSView {
    private weak var hostedView: NSView?
    private var hostedConstraints: [NSLayoutConstraint] = []

    func mount(_ view: NSView) {
        if hostedView === view, view.superview === self { return }
        unmountHostedView()
        if let previousContainer = view.superview as? TerminalMountContainerView,
           previousContainer !== self {
            previousContainer.releaseHostedViewReference(ifMatching: view)
        }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        hostedView = view
        hostedConstraints = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(hostedConstraints)
    }

    func unmountHostedView() {
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedConstraints.removeAll(keepingCapacity: false)
        if hostedView?.superview === self {
            hostedView?.removeFromSuperview()
        }
        hostedView = nil
    }

    private func releaseHostedViewReference(ifMatching view: NSView) {
        guard hostedView === view else { return }
        NSLayoutConstraint.deactivate(hostedConstraints)
        hostedConstraints.removeAll(keepingCapacity: false)
        hostedView = nil
    }
}

final class TerminalHostView: NSView {
    let terminalView = LocalProcessTerminalView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(preferences: TerminalPreferences) {
        apply(appearance: preferences.theme)
        applyFont(preferences: preferences)
        terminalView.optionAsMetaKey = preferences.optionAsMetaKey
        terminalView.allowMouseReporting = preferences.allowMouseReporting
        terminalView.backspaceSendsControlH = preferences.backspaceSendsControlH
        terminalView.useBrightColors = preferences.useBrightColors
        terminalView.linkReporting = preferences.linkMode.reporting
        terminalView.linkHighlightMode = preferences.linkMode.highlightMode
        terminalView.changeScrollback(preferences.scrollbackLines.rawValue)
    }

    private func apply(appearance: TerminalThemeAppearance) {
        let backgroundColor = appearance.backgroundColor
        let foregroundColor = appearance.foregroundColor
        layer?.backgroundColor = backgroundColor.cgColor
        terminalView.nativeBackgroundColor = backgroundColor
        terminalView.nativeForegroundColor = foregroundColor
        terminalView.selectedTextBackgroundColor = foregroundColor.withAlphaComponent(0.28)
        terminalView.caretColor = foregroundColor
        terminalView.caretTextColor = backgroundColor
        terminalView.installColors(appearance.ansiPalette.map(Self.makeTerminalColor(from:)))
    }

    private func applyFont(preferences: TerminalPreferences) {
        terminalView.font = preferences.fontFamily.font(size: preferences.fontSize)
    }

    private static func makeTerminalColor(from nsColor: NSColor) -> SwiftTerm.Color {
        let color = nsColor.usingColorSpace(.deviceRGB) ?? .black
        return SwiftTerm.Color(
            red: UInt16(color.redComponent * 65535),
            green: UInt16(color.greenComponent * 65535),
            blue: UInt16(color.blueComponent * 65535)
        )
    }
}
