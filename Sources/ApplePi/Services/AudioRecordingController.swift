import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class AudioRecordingController: NSObject, ObservableObject, AVAudioRecorderDelegate, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0.14, count: 20)

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var recordingStartedAt: Date?
    private var currentRecordingURL: URL?

    func startRecording() async throws {
        guard !isRecording else { return }
        let granted = await requestMicrophoneAccess()
        guard granted else {
            throw AudioRecordingError.microphonePermissionDenied
        }

        let outputURL = try makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecordingError.couldNotStart
        }

        self.recorder = recorder
        self.currentRecordingURL = outputURL
        self.recordingStartedAt = Date()
        self.elapsedTime = 0
        self.levels = Array(repeating: 0.14, count: 20)
        self.isRecording = true
        startMeterTimer()
    }

    func stopRecording() throws -> URL {
        guard isRecording, let recorder, let currentRecordingURL else {
            throw AudioRecordingError.notRecording
        }

        stopMeterTimer()
        recorder.stop()
        self.recorder = nil
        self.recordingStartedAt = nil
        self.isRecording = false
        self.elapsedTime = 0
        self.currentRecordingURL = nil
        return currentRecordingURL
    }

    func cancelRecording() {
        stopMeterTimer()
        recorder?.stop()
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        recordingStartedAt = nil
        currentRecordingURL = nil
        elapsedTime = 0
        levels = Array(repeating: 0.14, count: 20)
        isRecording = false
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor in
            self.isRecording = false
            self.stopMeterTimer()
        }
    }

    private func startMeterTimer() {
        stopMeterTimer()
        let timer = Timer(timeInterval: 0.08, target: self, selector: #selector(handleMeterTimer), userInfo: nil, repeats: true)
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    @objc private func handleMeterTimer() {
        updateMeters()
    }

    private func updateMeters() {
        guard let recorder else { return }
        recorder.updateMeters()
        if let recordingStartedAt {
            elapsedTime = Date().timeIntervalSince(recordingStartedAt)
        }
        let power = recorder.averagePower(forChannel: 0)
        let normalized = normalizedLevel(from: power)
        levels.append(normalized)
        if levels.count > 24 {
            levels.removeFirst(levels.count - 24)
        }
    }

    private func normalizedLevel(from power: Float) -> CGFloat {
        if power <= -80 {
            return 0.12
        }
        let normalized = max(0, min(1, (power + 80) / 80))
        return CGFloat(0.12 + (normalized * 0.88))
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        continuation.resume(returning: granted)
                    }
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func makeRecordingURL() throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ApplePiVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "voice-message-\(formatter.string(from: Date())).m4a"
        return tempDirectory.appendingPathComponent(fileName)
    }
}

enum AudioRecordingError: LocalizedError {
    case microphonePermissionDenied
    case couldNotStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it for Apple Pi in System Settings."
        case .couldNotStart:
            return "Could not start audio recording."
        case .notRecording:
            return "No active recording."
        }
    }
}
