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

    // MARK: - Engine State Machine

    /// Engine lifecycle state — protected by atomic lock to prevent race conditions
    enum EngineState {
        case stopped, warmingUp, running, broken
    }

    let engineState = OSAllocatedUnfairLock(initialState: EngineState.stopped)

    /// Task tracking ongoing warmup — cancelled if a new warmup starts
    private var warmupTask: Task<Void, Error>?

    // MARK: - Engine (stays running at all times)

    private var audioEngine: AVAudioEngine?
    private var cachedFormat: AVAudioFormat?

    /// Buffer flow timestamp for health verification — protected by atomic lock
    private let lastBufferTimestamp = OSAllocatedUnfairLock<Date?>(initialState: nil)

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
    private var interruptionObserver: NSObjectProtocol?

    /// Task tracking device change debounce — cancelled if another change occurs
    private var deviceChangeTask: Task<Void, Never>?

    private let logger = LoggingService.shared

    // MARK: - Engine Lifecycle

    /// Start the audio engine and install a permanent tap.
    /// Called once at app launch and again after audio device changes.
    /// The engine stays running — the tap discards buffers when not recording.
    /// This is now async and thread-safe with atomic state transitions.
    func warmUp() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Cancel existing warmup if any
        warmupTask?.cancel()

        // Atomic state check and transition (non-async to prevent actor reentrancy)
        let wasAlreadyWarming = engineState.withLock { state -> Bool in
            guard state != .warmingUp else {
                logger.error("Warmup already in progress, force-cancelling old task and retrying")
                return true
            }
            state = .warmingUp
            return false
        }

        // If was already warming up, force reset and retry
        if wasAlreadyWarming {
            engineState.withLock { $0 = .stopped }
            // Fall through to create a new warmup task
        }

        // Create a task for the actual warmup work
        warmupTask = Task { @MainActor [weak self] in
            do {
                try await self?.performWarmup()
                self?.engineState.withLock { $0 = .running }
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                self?.logger.info("warmUp() completed in \(String(format: "%.1f", elapsed))ms - State: running")
            } catch {
                // Always set final state, even on cancellation or other errors
                if Task.isCancelled {
                    self?.engineState.withLock { $0 = .stopped }
                    self?.logger.info("warmUp() cancelled - State: stopped")
                } else {
                    self?.engineState.withLock { $0 = .broken }
                    self?.logger.error("warmUp() failed - State: broken - Error: \(error.localizedDescription)")
                }
                throw error
            }
        }

        try await warmupTask?.value
    }

    /// Performs the actual audio engine initialization with timeout and health validation.
    /// Separated from warmUp() to enable proper async error handling and timeouts.
    private func performWarmup() async throws {
        logger.info("performWarmup() starting...")
        let setupStart = CFAbsoluteTimeGetCurrent()

        logger.debug("Creating AVAudioEngine instance")
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        logger.info("Creating AVAudioEngine - Sample rate: \(format.sampleRate)Hz, Channels: \(format.channelCount), Format: \(format.commonFormat.rawValue)")
        logger.info("Format details: isStandard=\(format.isStandard), commonFormat=\(format.commonFormat), sampleRate=\(format.sampleRate), channelCount=\(format.channelCount)")

        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.error("Invalid format: sampleRate=\(format.sampleRate), channelCount=\(format.channelCount)")
            throw RecorderError.noInputDevice
        }

        self.audioEngine = engine
        self.cachedFormat = format

        // Install a PERMANENT tap — never removed between recordings.
        // The isCapturing flag controls whether buffers are written or discarded.
        logger.debug("Installing audio tap on input node")
        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Log first few buffers to confirm tap is being called
            bufferCount += 1
            if bufferCount <= 3 {
                self.logger.info("Tap callback received buffer \(bufferCount): frameLength=\(buffer.frameLength), format=\(buffer.format)")
            }

            // Update buffer timestamp for health checks (always, not just during recording)
            self.lastBufferTimestamp.withLock { $0 = Date() }

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
        logger.debug("Audio tap installed successfully")

        logger.debug("Preparing engine...")
        engine.prepare()
        let prepareElapsed = (CFAbsoluteTimeGetCurrent() - setupStart) * 1000
        logger.debug("Engine prepared in \(String(format: "%.1f", prepareElapsed))ms")

        // Start with timeout protection (5 seconds max)
        logger.debug("Calling AVAudioEngine.start() with 5s timeout")
        let startStart = CFAbsoluteTimeGetCurrent()
        try await withTimeout(seconds: 5) {
            try engine.start()
        }
        let startElapsed = (CFAbsoluteTimeGetCurrent() - startStart) * 1000
        logger.debug("AVAudioEngine.start() completed in \(String(format: "%.1f", startElapsed))ms")

        // Wait for first buffer to verify health
        // 250ms accounts for macOS audio driver initialization variance.
        // Buffers typically arrive 100-150ms after engine.start(), with safety margin.
        logger.debug("Waiting 250ms for first audio buffer (macOS hardware initialization)...")
        try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        logger.debug("Sleep complete, verifying engine health...")
        try verifyEngineHealth()
        logger.debug("Engine health verified successfully")

        registerConfigChangeObserver(for: engine)
        registerInterruptionObserver()
        logger.info("Audio engine warmed up successfully - buffers flowing, ready for recording")
    }

    /// Executes an async operation with a timeout. If the operation exceeds the timeout,
    /// throws engineStartTimeout error. Properly cancels all child tasks on completion.
    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RecorderError.engineStartTimeout
            }

            // Get first result (either operation completes or timeout fires)
            do {
                guard let result = try await group.next() else {
                    throw RecorderError.engineStartTimeout
                }
                // Cancel remaining tasks (important: must happen before exiting scope)
                group.cancelAll()
                return result
            } catch {
                // Cancel remaining tasks on error
                group.cancelAll()
                throw error
            }
        }
    }

    /// Verifies that the audio engine is healthy by checking that buffers are flowing.
    /// Throws if no buffers have been received since warmup started.
    /// The 5 second threshold accounts for system under load and variable buffer delivery timing.
    private func verifyEngineHealth() throws {
        let lastBuffer = lastBufferTimestamp.withLock { $0 }

        guard let lastBuffer else {
            throw RecorderError.engineBroken("No audio buffers received during warmup")
        }

        let timeSinceLastBuffer = Date().timeIntervalSince(lastBuffer)
        // Allow up to 5 seconds for first buffer on heavily loaded systems
        guard timeSinceLastBuffer < 5.0 else {
            throw RecorderError.engineBroken("Audio buffers stopped flowing (no buffer in \(String(format: "%.1f", timeSinceLastBuffer))s)")
        }

        logger.debug("Engine health verified - Last buffer received \(String(format: "%.1f", timeSinceLastBuffer))s ago")
    }

    // MARK: - Recording

    func startRecording() throws {
        // Check engine state
        let engineState = engineState.withLock { $0 }

        logger.info("startRecording() called - Engine state: \(String(describing: engineState))")

        if engineState == .broken {
            throw RecorderError.engineBroken("Engine is in a broken state and requires recovery")
        }

        if engineState != .running {
            throw RecorderError.engineNotReady("Engine is not ready (state: \(String(describing: engineState)))")
        }

        // Verify engine health
        try verifyEngineHealth()

        guard let nativeFormat = cachedFormat else {
            throw RecorderError.noInputDevice
        }

        // Validate format is compatible with WAV
        guard nativeFormat.sampleRate <= 192000, nativeFormat.channelCount <= 2 else {
            logger.error("Audio format not WAV-compatible: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")
            throw RecorderError.formatCreationFailed
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

    // MARK: - Recovery

    /// Attempts to recover the audio engine from a broken state.
    /// Performs a hard reset and re-initializes the engine.
    func recoverEngine() async throws {
        logger.error("recoverEngine() called - Attempting recovery from broken state")

        // Cancel all ongoing tasks
        warmupTask?.cancel()
        deviceChangeTask?.cancel()

        // Hard reset: synchronous state transition
        engineState.withLock { $0 = .stopped }
        isCapturing.withLock { $0 = false }

        // Tear down engine
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        cachedFormat = nil
        lastBufferTimestamp.withLock { $0 = nil }

        logger.debug("Hard reset complete - waiting for audio hardware to settle")

        // Wait for hardware to settle
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Retry warmup
        logger.info("Retrying warmup after recovery reset")
        try await warmUp()
        logger.info("Engine recovery successful - Engine is running")
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

    /// Registers observer for audio engine configuration changes (device changes, etc.)
    /// Note: macOS doesn't have AVAudioSession interruptions like iOS does
    private func registerInterruptionObserver() {
        // On macOS, audio interruptions are handled differently than iOS.
        // Devices changes are handled via AVAudioEngineConfigurationChange notifications.
        // No need to set up additional interruption observers on macOS.
    }

    private func handleEngineConfigChange() {
        let wasCapturing = isCapturing.withLock { $0 }
        logger.info("AVAudioEngineConfigurationChange detected - Was capturing: \(wasCapturing)")

        // Cancel existing debounce if any
        deviceChangeTask?.cancel()

        // Debounce: wait 500ms for changes to settle before restarting
        logger.info("Device change debouncing for 500ms to allow changes to settle")
        deviceChangeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard !Task.isCancelled else {
                    self?.logger.info("Device change restart was cancelled")
                    return
                }

                // Verify self is still alive before proceeding
                guard let self else {
                    return
                }

                await self.performEngineRestart()
            } catch {
                // Only log if self is still alive (catch cancellation silently)
                if !Task.isCancelled {
                    self?.logger.error("Device change debounce task failed: \(error)")
                }
            }
        }
    }

    /// Performs the actual engine restart after device change debounce completes.
    private func performEngineRestart() async {
        logger.info("Debounce period elapsed - Beginning engine restart")

        // Cancel any ongoing warmup and wait briefly for it to wind down
        warmupTask?.cancel()
        do {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms for task to respond to cancellation
        } catch {
            // Ignore sleep cancellation
        }

        // Tear down current engine (synchronous)
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        cachedFormat = nil
        lastBufferTimestamp.withLock { $0 = nil }
        engineState.withLock { $0 = .stopped }

        logger.debug("Old engine torn down - Starting fresh warmup")

        // Restart with timeout
        do {
            try await warmUp()
            logger.info("Audio engine restarted successfully after device change")
        } catch {
            engineState.withLock { $0 = .broken }
            logger.error("Failed to restart after device change: \(error)")
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.state == .recording, let start = self.startTime else { return }
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
        case engineStartTimeout
        case engineBroken(String)
        case engineNotReady(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone input available. Check microphone permissions."
            case .formatCreationFailed:
                return "Failed to create audio format"
            case .engineStartTimeout:
                return "Audio engine timeout after 5 seconds. Device may be in use or unavailable."
            case .engineBroken(let reason):
                return "Audio engine error: \(reason)"
            case .engineNotReady(let reason):
                return "Audio engine not ready: \(reason)"
            }
        }
    }
}
