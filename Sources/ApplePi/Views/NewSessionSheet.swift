import SwiftUI

struct NewSessionSheet: View {
    @EnvironmentObject private var appState: PiAppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Session")
                        .font(.title2.weight(.semibold))
                    Text("Pi saves sessions by folder.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if appState.host.usesRemoteDaemonTransport || appState.host.mode == .remoteSSH {
                VStack(alignment: .leading, spacing: 12) {
                    RemoteFolderBrowser()
                    Divider()
                    TextField("Name", text: $appState.newSessionName)
                    Toggle("Temporary", isOn: $appState.newSessionIsTemporary)
                }
            } else {
                Form {
                    HStack {
                        TextField("Folder", text: $appState.newSessionWorkingDirectory)
                        Button {
                            appState.chooseNewSessionFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Choose folder")
                    }
                    TextField("Name", text: $appState.newSessionName)
                    Toggle("Temporary", isOn: $appState.newSessionIsTemporary)
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Start") {
                    appState.openNewSession()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: (appState.host.usesRemoteDaemonTransport || appState.host.mode == .remoteSSH) ? 640 : 520)
    }
}

private struct RemoteFolderBrowser: View {
    @EnvironmentObject private var appState: PiAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Remote folder", text: $appState.newSessionWorkingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appState.refreshRemoteDirectory()
                    }

                Button {
                    appState.openRemoteHomeDirectory()
                } label: {
                    Image(systemName: "house")
                }
                .help("Home")

                Button {
                    appState.openRemoteDirectoryParent()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(appState.remoteDirectoryParent == nil)
                .help("Parent folder")

                Button {
                    appState.refreshRemoteDirectory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            .buttonStyle(.borderless)

            ZStack {
                if appState.isLoadingRemoteDirectory {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.remoteDirectoryEntries.isEmpty {
                    Text(appState.remoteDirectoryStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(appState.remoteDirectoryEntries) { entry in
                                Button {
                                    appState.openRemoteDirectory(entry)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(appState.appearance.accentColor)
                                            .frame(width: 22)
                                        Text(entry.name)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                                    .opacity(0.4)
                            }
                        }
                    }
                }
            }
            .frame(height: 320)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(appState.remoteDirectoryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
