import AVFoundation
import Foundation
import os

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

    // MARK: - Engine (stays running at all times)

    private var audioEngine: AVAudioEngine?
    private var cachedFormat: AVAudioFormat?
    private var engineRunning = false

    /// Atomic flag checked from the audio render thread.
    /// When true, the tap callback writes buffers to the file writer.
    /// When false, buffers are silently discarded.
    private let isCapturing = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Recording state

    private var fileWriter: AudioFileWriter?
    private var tempFileURL: URL?
    private var timer: Timer?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0
    private var configChangeObserver: NSObjectProtocol?

    private let logger = LoggingService.shared

    // MARK: - Engine Lifecycle

    /// Start the audio engine and install a permanent tap.
    /// Called once at app launch and again after audio device changes.
    /// The engine stays running — the tap discards buffers when not recording.
    func warmUp() throws {
        guard !engineRunning else {
            logger.info("Audio engine already running, skipping warmUp")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        logger.info("Warming up audio engine: \(format.sampleRate)Hz, \(format.channelCount)ch, \(format.commonFormat.rawValue)")

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        self.audioEngine = engine
        self.cachedFormat = format

        // Install a PERMANENT tap — never removed between recordings.
        // The isCapturing flag controls whether buffers are written or discarded.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Fast atomic check — if not capturing, discard buffer immediately
            guard self.isCapturing.withLock({ $0 }) else { return }

            // Write buffer to file
            self.fileWriter?.write(from: buffer)

            // Calculate audio level for UI
            let level = AudioRecorder.calculateLevel(buffer: buffer)
            Task { @MainActor in
                self.audioLevel = level
            }
        }

        engine.prepare()
        try engine.start()

        engineRunning = true
        registerConfigChangeObserver(for: engine)
        logger.info("Audio engine warmed up and running (discarding buffers until recording starts)")
    }

    // MARK: - Recording

    func startRecording() throws {
        // Ensure engine is running (first recording or after device change)
        if !engineRunning {
            try warmUp()
        }

        guard let nativeFormat = cachedFormat else {
            throw RecorderError.noInputDevice
        }

        // Create temp WAV file
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("voicepolish_\(UUID().uuidString).wav")
        tempFileURL = fileURL

        let audioFile = try AVAudioFile(forWriting: fileURL, settings: nativeFormat.settings)
        let writer = AudioFileWriter(file: audioFile)
        self.fileWriter = writer

        logger.info("Recording file created. Format: \(audioFile.processingFormat.sampleRate)Hz, \(audioFile.processingFormat.channelCount)ch")

        // Flip the capture flag — recording starts on the very next audio callback
        isCapturing.withLock { $0 = true }

        state = .recording
        startTime = Date()
        accumulatedTime = 0
        recordingDuration = 0
        startTimer()

        logger.info("Recording started (capture flag enabled)")
    }

    func pauseRecording() {
        isCapturing.withLock { $0 = false }
        if let start = startTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        timer?.invalidate()
        timer = nil
        state = .paused
        logger.info("Recording paused at \(String(format: "%.1f", recordingDuration))s")
    }

    func resumeRecording() throws {
        // Engine is still running — just flip the flag back
        isCapturing.withLock { $0 = true }
        startTime = Date()
        startTimer()
        state = .recording
        logger.info("Recording resumed")
    }

    func stopRecording() -> URL? {
        // Stop capturing — buffers are discarded from this point
        isCapturing.withLock { $0 = false }

        // Engine stays running — do NOT stop or remove tap

        fileWriter?.close()
        fileWriter = nil
        timer?.invalidate()
        timer = nil

        if state == .recording, let start = startTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }

        state = .idle
        audioLevel = 0
        let url = tempFileURL
        logger.info("Recording stopped. Duration: \(String(format: "%.1f", accumulatedTime))s. Engine still running.")
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

    private func registerConfigChangeObserver(for engine: AVAudioEngine) {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleEngineConfigChange()
            }
        }
    }

    private func handleEngineConfigChange() {
        let wasCapturing = isCapturing.withLock { $0 }
        logger.info("Audio engine configuration changed (device change). Was capturing: \(wasCapturing)")

        // Tear down current engine
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        cachedFormat = nil
        engineRunning = false

        // Restart engine immediately with new device
        do {
            try warmUp()
            logger.info("Audio engine restarted after device change")
        } catch {
            logger.error("Failed to restart audio engine after device change: \(error)")
        }
    }

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
