import SwiftUI

/// View for a single open Pi session. The chat now has a real composer area:
/// a message input field plus a dedicated accessory block underneath that we
/// can keep customizing without touching the rest of the message list layout.
struct ChatSessionView: View {
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var session: ChatSession

    @State private var draftText = ""
    @State private var composerNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if !session.statusMessage.isEmpty || session.loadError != nil {
                Divider().opacity(0.25)
            }
            MessageListView(events: session.events)
            Divider().opacity(0.25)
            composerArea
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if !session.statusMessage.isEmpty || session.loadError != nil {
            HStack(spacing: 6) {
                Image(systemName: session.loadError == nil ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(session.loadError == nil ? Color.secondary : Color.red)
                Text(session.loadError ?? session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draftText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 140)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write a message…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                if let composerNotice {
                    Text(composerNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Composer UI is ready. Next step: wire Send + live stream through pi-appd.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Send") {
                    handleSendTapped()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ChatAccessoryPanel(
                transportLabel: appState.host.usesRemoteDaemonTransport ? "Remote API" : "Local Mac",
                workingDirectory: sessionWorkingDirectory,
                messageCount: sessionMessageCount,
                latestModel: latestModel,
                sessionID: sessionIdentifier,
                hasError: session.loadError != nil,
                draftLength: draftText.count
            )
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var sessionWorkingDirectory: String? {
        for event in session.events {
            if case .meta(let meta, _) = event {
                return meta.workingDirectory
            }
        }
        return nil
    }

    private var latestModel: String? {
        for event in session.events.reversed() {
            if case .message(let message, _) = event, let model = message.model?.nilIfBlank {
                return model
            }
        }
        return nil
    }

    private var sessionMessageCount: Int {
        session.events.reduce(into: 0) { count, event in
            if case .message = event {
                count += 1
            }
        }
    }

    private var sessionIdentifier: String {
        session.key
    }

    private func handleSendTapped() {
        composerNotice = "Send backend is not wired yet. UI is ready; next step is POST /send + stream."
    }
}

private struct ChatAccessoryPanel: View {
    let transportLabel: String
    let workingDirectory: String?
    let messageCount: Int
    let latestModel: String?
    let sessionID: String
    let hasError: Bool
    let draftLength: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accessory area")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AccessoryChip(title: "Transport", value: transportLabel)
                    if let workingDirectory, !workingDirectory.isEmpty {
                        AccessoryChip(title: "Folder", value: workingDirectory)
                    }
                    AccessoryChip(title: "Messages", value: "\(messageCount)")
                    if let latestModel {
                        AccessoryChip(title: "Model", value: latestModel)
                    }
                    AccessoryChip(title: "Draft", value: "\(draftLength) chars")
                    AccessoryChip(title: "Status", value: hasError ? "Error" : "OK")
                    AccessoryChip(title: "Session", value: sessionID)
                }
                .padding(.vertical, 2)
            }

            Text("This block is intentionally easy to customize. You can ask me to replace these chips with buttons, toggles, presets, file controls, model selectors, or any other chat-side tools.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AccessoryChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
