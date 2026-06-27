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
                    Text("Pi will start in the default workspace from Settings.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                LabeledContent("Workspace") {
                    Text(appState.newSessionWorkingDirectory.nilIfBlank ?? "Default workspace")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TextField("Name", text: $appState.newSessionName)
                Toggle("Temporary", isOn: $appState.newSessionIsTemporary)
            }
            .formStyle(.grouped)

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
        .frame(width: 520)
    }
}
