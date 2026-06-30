import SwiftUI
import AppKit
import ApplePiCore
import ApplePiRemote

struct UpdatePillView: View {
    let update: AvailableUpdate
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(.caption.weight(.semibold))
                Text("v\(update.latestVersion)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Open release page") {
                NSWorkspace.shared.open(update.releaseURL)
            }
            .buttonStyle(.link)
            .font(.caption.weight(.medium))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(16)
    }
}
