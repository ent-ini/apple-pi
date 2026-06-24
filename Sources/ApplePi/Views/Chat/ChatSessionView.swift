import AppKit
import SwiftUI

/// View for a single open Pi session. The composer stays compact but now
/// supports staged attachments above the input row.
struct ChatSessionView: View {
    @EnvironmentObject private var appState: PiAppState
    @ObservedObject var session: ChatSession

    @State private var draftText = ""
    @State private var draftHeight: CGFloat = 30
    @State private var draftAttachments: [ChatAttachment] = []
    @State private var isTranscribingAudio = false
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var showMicrophonePermissionAlert = false
    @State private var showsModelPicker = false
    @StateObject private var audioRecorder = AudioRecordingController()

    private let attachmentStagingService = AttachmentStagingService()

    private var canSend: Bool {
        !session.isSending && !audioRecorder.isRecording && !isTranscribingAudio && (
            !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !draftAttachments.isEmpty
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(session: session)
            Divider().opacity(0.25)
            composerArea
        }
        .onAppear {
            appState.refreshSessionRuntime(for: session)
            appState.refreshAvailableModels(for: session)
        }
        .onChange(of: session.sessionID) { _, _ in
            showsModelPicker = false
            appState.refreshSessionRuntime(for: session)
            appState.refreshAvailableModels(for: session, force: true)
        }
        .onDisappear {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            if audioRecorder.isRecording {
                audioRecorder.cancelRecording()
            }
            cleanupAttachments(draftAttachments)
        }
        .alert("Microphone Access Needed", isPresented: $showMicrophonePermissionAlert) {
            Button("Open Settings") {
                openMicrophoneSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access for Apple Pi in System Settings → Privacy & Security → Microphone.")
        }
    }

    private var composerArea: some View {
        let controlHeight = max(draftHeight, 30)

        return VStack(alignment: .leading, spacing: 10) {
            if !draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(draftAttachments) { attachment in
                            ComposerAttachmentPreview(
                                attachment: attachment,
                                onRemove: { removeAttachment(attachment) }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                composerIconButton(
                    systemName: "plus",
                    enabled: !audioRecorder.isRecording,
                    action: pickAttachments
                )
                .help("Attach files")

                composerInputSurface(controlHeight: controlHeight)

                composerIconButton(
                    systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill",
                    enabled: true,
                    foreground: audioRecorder.isRecording ? .red : appState.appearance.accentColor,
                    action: handleMicrophoneTapped
                )
                .help(audioRecorder.isRecording ? "Stop recording" : "Record voice note")

                composerIconButton(
                    systemName: "arrow.up",
                    enabled: canSend,
                    action: handleSendTapped
                )
                .help("Send")
            }

            sessionStatusStrip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sessionStatusStrip: some View {
        let runtime = session.runtimeState
        let contextPercent = max(0, min((runtime?.contextUsage?.percent ?? 0) / 100, 1))

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(appState.appearance.accentColor.opacity(0.9))
                        .frame(width: proxy.size.width * contextPercent)
                }
            }
            .frame(height: 4)

            HStack(alignment: .center, spacing: 8) {
                Text(statusMetricsText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 92, alignment: .leading)

                Spacer(minLength: 0)

                Button {
                    if session.availableModels.isEmpty {
                        appState.refreshAvailableModels(for: session, force: true)
                    }
                    withAnimation(.snappy(duration: 0.18)) {
                        showsModelPicker.toggle()
                    }
                } label: {
                    statusPill(title: runtime?.modelDisplayName ?? "model", showsChevron: true, chevronExpanded: showsModelPicker)
                }
                .buttonStyle(.plain)
                .disabled(session.sessionID == nil)
                .overlay(alignment: .bottomTrailing) {
                    if showsModelPicker {
                        modelPickerList
                            .offset(y: -30)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .zIndex(5)
                    }
                }
                .zIndex(5)

                Button {
                    showsModelPicker = false
                    appState.cycleThinkingLevel(in: session)
                } label: {
                    statusPill(title: "thinking: \(runtime?.thinkingLevel ?? "off")")
                }
                .buttonStyle(.plain)
                .disabled(session.sessionID == nil)
            }
        }
    }

    private var statusMetricsText: String {
        let runtime = session.runtimeState
        let tokens = runtime?.tokens ?? .zero
        let context = runtime?.contextUsage
        let used = formatCompactTokenCount(context?.tokens)
        let window = formatCompactTokenCount(context?.contextWindow)
        return "↓\(formatCompactTokenCount(tokens.output)) ↑\(formatCompactTokenCount(tokens.input)) \(used)/\(window)"
    }

    private var groupedModels: [(provider: String, models: [PiModelOption])] {
        Dictionary(grouping: session.availableModels, by: \.provider)
            .map { key, value in
                (provider: key, models: value.sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending })
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private var modelPickerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if groupedModels.isEmpty {
                    Text("Loading models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ForEach(groupedModels, id: \.provider) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.provider)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)

                            ForEach(group.models) { model in
                                Button {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        showsModelPicker = false
                                    }
                                    appState.selectModel(model, in: session)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(model.shortLabel)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(isCurrentModel(model) ? appState.appearance.accentColor : .secondary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        if isCurrentModel(model) {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(appState.appearance.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isCurrentModel(model) ? appState.appearance.accentColor.opacity(0.1) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 220, maxHeight: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func isCurrentModel(_ model: PiModelOption) -> Bool {
        session.runtimeState?.provider == model.provider && session.runtimeState?.modelID == model.modelID
    }

    private func statusPill(title: String, showsChevron: Bool = false, chevronExpanded: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(chevronExpanded ? 180 : 0))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func formatCompactTokenCount(_ value: Int?) -> String {
        guard let value else { return "?" }
        if value < 1_000 { return "\(value)" }
        if value < 10_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        if value < 1_000_000 { return "\(Int(round(Double(value) / 1_000)))k" }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    @ViewBuilder
    private func composerInputSurface(controlHeight: CGFloat) -> some View {
        if audioRecorder.isRecording || isTranscribingAudio {
            HStack(spacing: 10) {
                if audioRecorder.isRecording {
                    VoiceWaveformView(levels: audioRecorder.levels, tint: appState.appearance.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

                    Text(formattedDuration(audioRecorder.elapsedTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: controlHeight, maxHeight: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            )
        } else {
            ComposerTextView(
                text: $draftText,
                dynamicHeight: $draftHeight,
                onSubmit: handleSendTapped,
                onPasteAttachments: handlePasteAttachments
            )
            .frame(maxWidth: .infinity, minHeight: controlHeight, maxHeight: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
    }

    @ViewBuilder
    private func composerIconButton(
        systemName: String,
        enabled: Bool,
        foreground: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle((foreground ?? appState.appearance.accentColor).opacity(enabled ? 1 : 0.28))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .padding(2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func handleSendTapped() {
        let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if appState.sendMessage(prompt, attachments: draftAttachments, in: session) {
            draftText = ""
            draftHeight = 30
            draftAttachments = []
        }
    }

    private func handleMicrophoneTapped() {
        if audioRecorder.isRecording {
            finishVoiceRecording()
            return
        }

        if isTranscribingAudio {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            isTranscribingAudio = false
        }

        let status = AudioRecordingController.microphoneAuthorizationStatus()
        switch status {
        case .authorized:
            startRecordingNow()
        case .notDetermined:
            appState.statusMessage = "Requesting microphone access..."
            AudioRecordingController.requestMicrophoneAccess { granted in
                Task { @MainActor in
                    if granted {
                        startRecordingNow()
                    } else {
                        appState.statusMessage = AudioRecordingError.microphonePermissionDenied.localizedDescription
                        showMicrophonePermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            appState.statusMessage = AudioRecordingError.microphonePermissionDenied.localizedDescription
            showMicrophonePermissionAlert = true
        @unknown default:
            appState.statusMessage = AudioRecordingError.microphonePermissionDenied.localizedDescription
            showMicrophonePermissionAlert = true
        }
    }

    private func startRecordingNow() {
        do {
            try audioRecorder.startRecordingAuthorized()
            appState.statusMessage = "Recording voice note..."
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func finishVoiceRecording() {
        do {
            let recordingURL = try audioRecorder.stopRecording()
            let staged = try attachmentStagingService.stageFile(at: recordingURL)
            try? FileManager.default.removeItem(at: recordingURL)
            transcribeAudioAttachmentIfPossible(staged)
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func transcribeAudioAttachmentIfPossible(_ attachment: ChatAttachment) {
        guard attachment.kind == .audio else { return }
        guard let apiKey = appState.groqAPIKey() else {
            cleanupAttachments([attachment])
            appState.statusMessage = "Save a Groq API key in Settings to enable voice transcription."
            return
        }

        let fileURL = attachment.fileURL
        isTranscribingAudio = true
        appState.statusMessage = "Transcribing voice note..."
        transcriptionTask?.cancel()
        transcriptionTask = Task {
            do {
                let transcript = try await GroqTranscriptionClient().transcribeAudio(at: fileURL, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    mergeTranscript(transcript)
                    isTranscribingAudio = false
                    transcriptionTask = nil
                    cleanupAttachments([attachment])
                    appState.statusMessage = "Voice note transcribed"
                }
            } catch is CancellationError {
                await MainActor.run {
                    isTranscribingAudio = false
                    transcriptionTask = nil
                    cleanupAttachments([attachment])
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTranscribingAudio = false
                    transcriptionTask = nil
                    cleanupAttachments([attachment])
                    appState.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func mergeTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftText = trimmed
        } else if draftText.hasSuffix("\n") {
            draftText += trimmed
        } else {
            draftText += "\n\n\(trimmed)"
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.title = "Choose files or images"

        guard panel.runModal() == .OK else { return }
        addAttachments(from: panel.urls)
    }

    private func handlePasteAttachments(_ pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            addAttachments(from: urls)
            return
        }

        if let rawFileNames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           !rawFileNames.isEmpty {
            addAttachments(from: rawFileNames.map(URL.init(fileURLWithPath:)))
            return
        }

        do {
            if let stagedImage = try attachmentStagingService.stagePastedImage(from: pasteboard) {
                appendAttachments([stagedImage])
            }
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func addAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let staged = try urls.map { try attachmentStagingService.stageFile(at: $0) }
            appendAttachments(staged)
        } catch {
            appState.statusMessage = error.localizedDescription
        }
    }

    private func appendAttachments(_ attachments: [ChatAttachment]) {
        for attachment in attachments where !draftAttachments.contains(where: { $0.fileURL == attachment.fileURL }) {
            draftAttachments.append(attachment)
        }
    }

    private func removeAttachment(_ attachment: ChatAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
        cleanupAttachments([attachment])
    }

    private func cleanupAttachments(_ attachments: [ChatAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.fileURL)
        }
    }

    private func formattedDuration(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct ComposerAttachmentPreview: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.isImage, let image = NSImage(contentsOf: attachment.fileURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipped()
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: attachment.kind == .audio ? "waveform" : "doc")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(attachment.displayName)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(width: 160, height: 64, alignment: .leading)
                    .padding(.horizontal, 10)
                }
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .frame(width: attachment.isImage ? 84 : 160, height: attachment.isImage ? 84 : 64)
    }
}

private struct VoiceWaveformView: View {
    let levels: [CGFloat]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let samples = interpolatedLevels(targetCount: max(12, Int(geometry.size.width / 5)))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint.opacity(0.92))
                        .frame(width: max(2, (geometry.size.width / CGFloat(max(samples.count, 1))) - 2), height: max(CGFloat(4), geometry.size.height * level))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }

    private func interpolatedLevels(targetCount: Int) -> [CGFloat] {
        guard !levels.isEmpty else { return Array(repeating: 0.12, count: targetCount) }
        guard targetCount > 0 else { return levels }
        if levels.count == targetCount { return levels }
        if levels.count == 1 { return Array(repeating: levels[0], count: targetCount) }

        return (0..<targetCount).map { index in
            let position = CGFloat(index) * CGFloat(levels.count - 1) / CGFloat(max(targetCount - 1, 1))
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, levels.count - 1)
            let fraction = position - CGFloat(lower)
            let start = levels[lower]
            let end = levels[upper]
            return start + ((end - start) * fraction)
        }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var dynamicHeight: CGFloat
    let onSubmit: () -> Void
    let onPasteAttachments: (NSPasteboard) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            dynamicHeight: $dynamicHeight,
            onSubmit: onSubmit,
            onPasteAttachments: onPasteAttachments
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.focusRingType = .none
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor.clear.cgColor

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteAttachments = onPasteAttachments
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 20)
        textView.focusRingType = .none
        textView.string = text
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: max(dynamicHeight, 30))

        scrollView.documentView = textView
        scrollView.composerTextView = textView
        context.coordinator.textView = textView
        Task { @MainActor in
            context.coordinator.recalculateHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onPasteAttachments = onPasteAttachments
        if textView.string != text {
            textView.string = text
        }
        if let composerScrollView = scrollView as? ComposerScrollView {
            composerScrollView.composerTextView = textView
            composerScrollView.needsLayout = true
            composerScrollView.layoutSubtreeIfNeeded()
        }
        Task { @MainActor in
            context.coordinator.recalculateHeight(for: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var dynamicHeight: CGFloat
        let onSubmit: () -> Void
        let onPasteAttachments: (NSPasteboard) -> Void
        weak var textView: ComposerNSTextView?

        init(
            text: Binding<String>,
            dynamicHeight: Binding<CGFloat>,
            onSubmit: @escaping () -> Void,
            onPasteAttachments: @escaping (NSPasteboard) -> Void
        ) {
            self._text = text
            self._dynamicHeight = dynamicHeight
            self.onSubmit = onSubmit
            self.onPasteAttachments = onPasteAttachments
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
            textView.enclosingScrollView?.needsLayout = true
            textView.enclosingScrollView?.layoutSubtreeIfNeeded()
            Task { @MainActor in
                self.recalculateHeight(for: textView)
            }
        }

        @MainActor
        func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let next = min(max(usedRect.height + textView.textContainerInset.height * 2, 30), 140)
            if abs(dynamicHeight - next) > 0.5 {
                dynamicHeight = next
            }
        }
    }
}

private final class ComposerScrollView: NSScrollView {
    weak var composerTextView: NSTextView?

    override func layout() {
        super.layout()
        guard let textView = composerTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleWidth = contentView.bounds.width
        guard visibleWidth > 0 else { return }

        textContainer.containerSize = NSSize(width: visibleWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let fittedHeight = max(usedRect.height + textView.textContainerInset.height * 2, textView.minSize.height)
        textView.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: fittedHeight)
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteAttachments: ((NSPasteboard) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            let pasteboard = NSPasteboard.general
            if Self.hasAttachmentPayload(in: pasteboard) {
                onPasteAttachments?(pasteboard)
                return
            }
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if Self.hasAttachmentPayload(in: pasteboard) {
            onPasteAttachments?(pasteboard)
            return
        }
        super.paste(sender)
    }

    private static func hasAttachmentPayload(in pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return true
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        let supportedTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .png,
            .tiff,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ]
        return pasteboard.types?.contains(where: { supportedTypes.contains($0) }) == true
    }
}
