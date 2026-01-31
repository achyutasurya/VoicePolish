import AVFoundation
import Foundation

// Thread-safe wrapper for AVAudioFile used from the audio tap callback
private final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?

    init(file: AVAudioFile) {
        self.file = file
    }

    func write(from buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}

@MainActor
@Observable
final class AudioRecorder {
    enum State {
        case idle, recording, paused
    }

    var state: State = .idle
    var recordingDuration: TimeInterval = 0
    var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var fileWriter: AudioFileWriter?
    private var tempFileURL: URL?
    private var timer: Timer?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0

    private let logger = LoggingService.shared

    func startRecording() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        logger.info("Input format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch, \(nativeFormat.commonFormat.rawValue)")

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // Create temp WAV file
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("voiceink_\(UUID().uuidString).wav")
        tempFileURL = fileURL

        // Record in native format — no conversion needed
        // Deepgram accepts WAV at any sample rate
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: nativeFormat.settings)
        let writer = AudioFileWriter(file: audioFile)
        self.fileWriter = writer

        logger.info("AVAudioFile created. Processing format: \(audioFile.processingFormat.sampleRate)Hz, \(audioFile.processingFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            // Write buffer directly — format matches, no conversion
            writer.write(from: buffer)

            // Calculate audio level for UI
            let level = AudioRecorder.calculateLevel(buffer: buffer)
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        state = .recording
        startTime = Date()
        accumulatedTime = 0
        recordingDuration = 0
        startTimer()

        logger.info("Recording started successfully")
    }

    func pauseRecording() {
        audioEngine?.pause()
        if let start = startTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        timer?.invalidate()
        timer = nil
        state = .paused
        logger.info("Recording paused at \(String(format: "%.1f", recordingDuration))s")
    }

    func resumeRecording() throws {
        try audioEngine?.start()
        startTime = Date()
        startTimer()
        state = .recording
        logger.info("Recording resumed")
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        fileWriter?.close()
        fileWriter = nil
        timer?.invalidate()
        timer = nil

        if state == .recording, let start = startTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }

        state = .idle
        let url = tempFileURL
        logger.info("Recording stopped. Duration: \(String(format: "%.1f", accumulatedTime))s")
        return url
    }

    func cancelRecording() {
        let url = stopRecording()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        tempFileURL = nil
        recordingDuration = 0
        audioLevel = 0
        logger.info("Recording cancelled")
    }

    func getAudioData() -> Data? {
        guard let url = tempFileURL else {
            logger.error("getAudioData: no temp file URL")
            return nil
        }
        let data = try? Data(contentsOf: url)
        logger.info("Audio data: \(data?.count ?? 0) bytes")
        try? FileManager.default.removeItem(at: url)
        tempFileURL = nil
        return data
    }

    // MARK: - Private

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording, let start = self.startTime else { return }
                self.recordingDuration = self.accumulatedTime + Date().timeIntervalSince(start)
            }
        }
    }

    nonisolated static func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            sum += abs(channelData[i])
        }
        let avg = sum / Float(frames)
        return min(avg * 5, 1.0)
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case formatCreationFailed

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone input available. Check microphone permissions."
            case .formatCreationFailed: return "Failed to create audio format"
            }
        }
    }
}
