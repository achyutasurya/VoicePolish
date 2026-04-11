import AVFoundation
import CoreAudio
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

/// Wrapper to safely transfer non-Sendable AVAudioEngine setup across actor boundaries.
/// Used to move engine creation off the MainActor to prevent blocking the UI thread.
private struct EngineSetup: @unchecked Sendable {
    let engine: AVAudioEngine
    let inputNode: AVAudioNode
    let format: AVAudioFormat
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
    var currentInputDeviceName: String = "Unknown"

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

    /// First-buffer arrival flag, set from inside the tap callback on first invocation.
    /// Added in v0.3.10 to close a race in the old buffer-polling loop: the poll loop
    /// sampled `lastBufferTimestamp` from outside the tap thread, creating a window
    /// where the poll woke up before the buffer was actually written. Setting a flag
    /// from within the tap block and waiting on it via `withTimeout` is race-free.
    /// Reset to false at the start of every `performWarmup()`.
    private let firstBufferReceived = OSAllocatedUnfairLock(initialState: false)

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

    // MARK: - Recovery ladder state (v0.3.12)
    //
    // Replaces the one-shot recovery from commit 8fbcc0d with a bounded exponential
    // backoff ladder. Designed to handle repeated transient failures (device swap
    // bursts, HAL reconfiguration races) without tripping .broken on the first miss.
    // Counter is reset to 0 from inside the tap callback when firstBufferReceived
    // flips true — that's the only rock-solid signal that recovery actually worked.
    // Start success of engine.start() is NOT a sufficient signal (see commit v0.3.10).
    private var recoveryAttempt: Int = 0
    private let maxRecoveryAttempts = 5
    /// Backoff delays in nanoseconds, indexed by attempt number.
    /// Total budget across 5 attempts = ~8.75s.
    private let backoffLadder: [UInt64] = [
        0,              // attempt 0: immediate retry
        250_000_000,    // attempt 1: 250ms
        500_000_000,    // attempt 2: 500ms
        1_000_000_000,  // attempt 3: 1s
        2_000_000_000,  // attempt 4: 2s
        5_000_000_000,  // attempt 5: 5s
    ]

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

        // Create a task for the actual warmup work (state management is below)
        warmupTask = Task { @MainActor [weak self] in
            try await self?.performWarmup()
        }

        // Await warmup with 10-second overall timeout.
        // This protects against CoreAudio hanging on device graph reconfiguration
        // (observed: AVAudioEngine()/inputNode can block for 9+ minutes).
        let taskToAwait = warmupTask
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await taskToAwait?.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    throw RecorderError.engineStartTimeout
                }
                guard let _ = try await group.next() else {
                    throw RecorderError.engineStartTimeout
                }
                group.cancelAll()
            }

            // Warmup succeeded
            engineState.withLock { $0 = .running }
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info("warmUp() completed in \(String(format: "%.1f", elapsed))ms - State: running")
        } catch {
            // Cancel warmup task if still running (e.g., CoreAudio hung past timeout)
            warmupTask?.cancel()

            if Task.isCancelled {
                engineState.withLock { $0 = .stopped }
                logger.info("warmUp() cancelled - State: stopped")
            } else {
                // Transient error classification (v0.3.11).
                // Known transient CoreAudio HAL codes (FourCC in parens):
                //   560227702  kAudioHardwareBadDeviceError         '!dev'
                //   1937010544 kAudioHardwareNotRunningError        'stop'
                //   560161383  kAudioHardwareIllegalOperationError  '!op '
                // These all surface during device-graph reconfiguration races and
                // are almost always resolved by the next retry. Plus our own
                // RecorderError.isTransient cases (deviceNotReady, engineStartTimeout,
                // Stale format, No audio buffers).
                //
                // Transient errors route to .stopped so the backoff ladder in
                // commit v0.3.12's recoverEngine() can retry them. Only unknown/
                // terminal errors enter .broken.
                // Ref: https://www.osstatus.com/search/results?platform=all&framework=all&search=560227702
                let transientHALCodes: Set<Int> = [
                    560227702,   // kAudioHardwareBadDeviceError '!dev'
                    1937010544,  // kAudioHardwareNotRunningError 'stop'
                    560161383,   // kAudioHardwareIllegalOperationError '!op '
                ]
                let nsError = error as NSError
                let isTransientRecorderError = (error as? RecorderError)?.isTransient == true
                let isTransientHALCode = transientHALCodes.contains(nsError.code)

                if isTransientRecorderError || isTransientHALCode {
                    engineState.withLock { $0 = .stopped }
                    logger.info("warmUp() hit transient condition (code=\(nsError.code)) - State: stopped (retryable via ladder)")
                } else {
                    engineState.withLock { $0 = .broken }
                    logger.error("warmUp() failed - State: broken - Error: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    /// Performs the actual audio engine initialization with timeout and health validation.
    /// Separated from warmUp() to enable proper async error handling and timeouts.
    private func performWarmup() async throws {
        logger.info("performWarmup() starting...")
        let setupStart = CFAbsoluteTimeGetCurrent()

        // Reset first-buffer flag for this warmup pass (v0.3.10). This flag is set
        // from inside the tap callback on first invocation and waited on by the
        // post-start withTimeout below. Must reset BEFORE the tap is installed so
        // we don't accidentally observe a stale `true` from the previous engine.
        firstBufferReceived.withLock { $0 = false }

        // CoreAudio HAL preflight (v0.3.11). Before calling AVAudioEngine(), confirm
        // that the default input device is non-zero, alive, and has at least one
        // input stream with at least one channel. Closes the kAudioHardwareBadDeviceError
        // (!dev 560227702) race where the device ID has become stale during a device
        // swap but CoreAudio hasn't finished reconfiguring. 1.5s budget fits inside
        // the 10s overall warmup cap from commit 539a750.
        let preflightStart = CFAbsoluteTimeGetCurrent()
        guard let readyDeviceID = await waitForDefaultInputDeviceReady(timeout: 1.5) else {
            let preflightElapsed = (CFAbsoluteTimeGetCurrent() - preflightStart) * 1000
            logger.error("HAL preflight timed out after \(String(format: "%.0f", preflightElapsed))ms — device not alive or no input streams")
            throw RecorderError.deviceNotReady("No alive default input device with input streams after 1.5s")
        }
        let preflightElapsed = (CFAbsoluteTimeGetCurrent() - preflightStart) * 1000
        logger.debug("HAL preflight passed in \(String(format: "%.0f", preflightElapsed))ms — device \(readyDeviceID) alive and streaming")

        // Log current default input device for diagnostics
        if let deviceInfo = getDefaultInputDeviceName() {
            logger.info("Audio input device: \"\(deviceInfo.name)\" (UID: \(deviceInfo.uid))")
            currentInputDeviceName = deviceInfo.name
        } else {
            logger.error("Could not query default input device")
            currentInputDeviceName = "Unknown"
        }

        // Run engine creation on a detached task to prevent blocking the MainActor.
        // AVAudioEngine(), inputNode, and outputFormat() are synchronous CoreAudio calls
        // that can hang for minutes during audio device graph reconfiguration.
        // Running them off-MainActor allows the 10-second warmup timeout to actually fire.
        //
        // v0.3.10: Format reconciliation (WhisperKit pattern).
        // `outputFormat(forBus: 0)` can briefly return 0 ch / 0 Hz or the previous
        // device's format immediately after an AVAudioEngineConfigurationChange.
        // Installing a tap with that stale format causes engine.start() to succeed
        // but no buffers ever flow. `inputFormat(forBus: 0)` reflects the actual
        // hardware sample rate, which is always current. Take the hardware sample
        // rate and the rest of the fields from outputFormat to construct a fresh,
        // consistent AVAudioFormat for the tap.
        // Ref: WhisperKit AudioProcessor.swift ~L974
        //      https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Audio/AudioProcessor.swift
        //      https://www.mail-archive.com/coreaudio-api@lists.apple.com/msg01754.html
        logger.debug("Creating AVAudioEngine instance (off MainActor to prevent UI freeze)")
        let engineCreateStart = CFAbsoluteTimeGetCurrent()
        let setup = try await Task.detached { () throws -> EngineSetup in
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let outputFormat = inputNode.outputFormat(forBus: 0)
            let hardwareSampleRate = inputNode.inputFormat(forBus: 0).sampleRate

            // Validate the hardware side of the query. If either is zero here, the
            // graph is in a transitional state and installTap would fail silently.
            guard hardwareSampleRate > 0, outputFormat.channelCount > 0 else {
                throw RecorderError.engineBroken("Stale format during warmup: hardwareSampleRate=\(hardwareSampleRate), outputChannels=\(outputFormat.channelCount)")
            }

            guard let reconciledFormat = AVAudioFormat(
                commonFormat: outputFormat.commonFormat,
                sampleRate: hardwareSampleRate,
                channels: outputFormat.channelCount,
                interleaved: outputFormat.isInterleaved
            ) else {
                throw RecorderError.formatCreationFailed
            }

            return EngineSetup(engine: engine, inputNode: inputNode, format: reconciledFormat)
        }.value
        let engineCreateElapsed = (CFAbsoluteTimeGetCurrent() - engineCreateStart) * 1000
        logger.debug("AVAudioEngine created in \(String(format: "%.1f", engineCreateElapsed))ms")

        // Bail out early if we were cancelled while waiting for engine creation
        // (e.g., timeout fired while CoreAudio was slow)
        try Task.checkCancellation()

        let engine = setup.engine
        let inputNode = setup.inputNode
        let format = setup.format

        logger.info("Engine format - Sample rate: \(format.sampleRate)Hz, Channels: \(format.channelCount), Format: \(format.commonFormat.rawValue)")
        logger.info("Format details: isStandard=\(format.isStandard), commonFormat=\(format.commonFormat), sampleRate=\(format.sampleRate), channelCount=\(format.channelCount)")

        // Warn if format doesn't look like a typical microphone
        if format.sampleRate == 44100 && format.channelCount == 2 {
            logger.error("WARNING: Format (44100Hz, 2ch) may indicate wrong input device — expected mono microphone input")
        } else if format.channelCount > 1 {
            logger.info("NOTE: Input format has \(format.channelCount) channels — stereo input detected")
        }

        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.error("Invalid format: sampleRate=\(format.sampleRate), channelCount=\(format.channelCount)")
            throw RecorderError.noInputDevice
        }

        self.audioEngine = engine
        self.cachedFormat = format

        // Check cancellation before installing tap (prevents orphaned tap if timeout fired)
        try Task.checkCancellation()

        // Install a PERMANENT tap — never removed between recordings.
        // The isCapturing flag controls whether buffers are written or discarded.
        logger.debug("Installing audio tap on input node with reconciled format")
        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // Log first few buffers to confirm tap is being called
            bufferCount += 1
            if bufferCount <= 3 {
                self.logger.info("Tap callback received buffer \(bufferCount): frameLength=\(buffer.frameLength), format=\(buffer.format)")
            }

            // Signal first-buffer arrival for the warmup withTimeout wait (v0.3.10).
            // Must happen BEFORE the isCapturing check so warmup can confirm the
            // tap is actually firing, not just that engine.start() returned.
            // Commit a7199b1 (0.3.3) established the same rule for lastBufferTimestamp.
            //
            // v0.3.12: Also reset the recoveryAttempt counter the first time the
            // tap fires in a new engine. This is THE signal that recovery worked
            // end-to-end; resetting on engine.start() returning is insufficient
            // because start() can succeed without buffers flowing (see v0.3.10).
            let wasFirst = self.firstBufferReceived.withLock { flag -> Bool in
                if !flag { flag = true; return true }
                return false
            }
            if wasFirst {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.recoveryAttempt > 0 {
                        self.logger.info("First buffer received — resetting recoveryAttempt \(self.recoveryAttempt) → 0")
                    }
                    self.recoveryAttempt = 0
                }
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

        // Check cancellation before starting engine
        try Task.checkCancellation()

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

        // Reset buffer timestamp to ensure we only detect NEW engine's buffers,
        // not stale timestamps from a previous engine instance.
        lastBufferTimestamp.withLock { $0 = nil }

        // Wait for first buffer to actually arrive at the tap (v0.3.10).
        // The `firstBufferReceived` flag is set from INSIDE the tap callback (see
        // installTap block above), which is race-free vs. the old polling loop
        // that sampled lastBufferTimestamp from outside the tap thread.
        //
        // Timeout bumped from 2s to 3s to accommodate post-device-swap settling:
        // Apple Developer Forum thread 683348 documents 500ms+ settle times after
        // AVAudioEngineConfigurationChange. Healthy graph still returns in ~100-150ms.
        // Total warmup still bounded by the 10s overall cap in warmUp().
        //
        // Uses withThrowingTaskGroup inline (same pattern as the 10s overall timeout
        // in warmUp()) because the existing withTimeout() helper only takes a sync
        // closure and this wait needs Task.sleep inside.
        logger.debug("Waiting for first audio buffer (up to 3s)...")
        let firstBufferStart = CFAbsoluteTimeGetCurrent()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                while !self.firstBufferReceived.withLock({ $0 }) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 25_000_000) // 25ms
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                throw RecorderError.engineBroken("No audio buffers received during warmup (3s timeout)")
            }
            // Wait for whichever task finishes first (flag set → success, or timeout → throw)
            guard let _ = try await group.next() else {
                throw RecorderError.engineBroken("First-buffer wait group returned no result")
            }
            group.cancelAll()
        }
        let firstBufferElapsed = (CFAbsoluteTimeGetCurrent() - firstBufferStart) * 1000
        logger.debug("First buffer received after \(String(format: "%.1f", firstBufferElapsed))ms")

        logger.debug("First-buffer wait complete, verifying engine health...")
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

    /// WhisperKit-style full teardown (v0.3.12). Takes the engine all the way
    /// back to nil so the next warmup builds from a genuinely clean graph.
    /// Partial reuse across retries is what the stale-format bug from v0.3.10
    /// cares about — we must not hope the prior state is cleanable.
    /// Ref: WhisperKit AudioProcessor.swift stopRecording ~L1086
    ///      https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Audio/AudioProcessor.swift
    private func performFullTeardown() {
        // Stop capturing flag (commit af2f28f) — tap callbacks become no-ops
        isCapturing.withLock { $0 = false }

        // Remove observers first so they don't fire during teardown
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }

        // WhisperKit canonical teardown sequence:
        //   removeTap → disconnectNodeInput → stop → reset → nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.disconnectNodeInput(engine.inputNode)
            engine.stop()
            engine.reset()
        }
        audioEngine = nil
        cachedFormat = nil
        lastBufferTimestamp.withLock { $0 = nil }
        firstBufferReceived.withLock { $0 = false }
        engineState.withLock { $0 = .stopped }
    }

    /// Walks the exponential backoff ladder, tearing down and re-warming up the
    /// engine on each attempt (v0.3.12). Replaces the one-shot recovery from
    /// commit 8fbcc0d which marked the engine .broken after a single failure.
    ///
    /// Attempts 1-5 with delays [0, 250ms, 500ms, 1s, 2s, 5s]. Total budget: ~8.75s.
    /// Counter is reset to 0 from the tap callback when first buffer arrives
    /// (the rock-solid signal of successful recovery). If the ladder exhausts,
    /// state transitions to .broken and the caller sees a permanent error.
    ///
    /// Ref plan file ~/.claude/plans/abstract-rolling-babbage.md Commit 5.
    func recoverEngine() async throws {
        logger.info("recoverEngine() called - Starting backoff ladder (attempt=\(recoveryAttempt)/\(maxRecoveryAttempts))")

        // Cancel any lingering tasks before starting the ladder
        warmupTask?.cancel()
        deviceChangeTask?.cancel()

        while recoveryAttempt < maxRecoveryAttempts {
            let delay = backoffLadder[min(recoveryAttempt, backoffLadder.count - 1)]
            if delay > 0 {
                logger.info("Recovery attempt \(recoveryAttempt + 1)/\(maxRecoveryAttempts): waiting \(delay / 1_000_000)ms before retry")
                try await Task.sleep(nanoseconds: delay)
            }

            // Full teardown before each attempt — WhisperKit canonical sequence
            performFullTeardown()

            // Retry warmup. If this succeeds, the tap callback will reset
            // recoveryAttempt to 0 from inside the tap block.
            do {
                try await warmUp()
                logger.info("Recovery attempt \(recoveryAttempt + 1) succeeded — engine is running")
                // recoveryAttempt has been (or will be) reset by the tap callback
                return
            } catch {
                logger.error("Recovery attempt \(recoveryAttempt + 1) failed: \(error.localizedDescription)")
                recoveryAttempt += 1
            }
        }

        // Ladder exhausted — engine is permanently broken until manual retry
        engineState.withLock { $0 = .broken }
        logger.error("Recovery ladder exhausted after \(maxRecoveryAttempts) attempts — engine permanently broken")
        throw RecorderError.engineBroken("Recovery ladder exhausted after \(maxRecoveryAttempts) attempts")
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

        // Debounce: wait 750ms for changes to settle before restarting (v0.3.12).
        // Commit dc3e8e4 originally set this to 500ms, but community sources
        // (audiodog.co.uk, Apple Developer Forums, Liscio's AirPods blog) confirm
        // that Bluetooth reconnects and USB-dock switches fire 2-4 notifications
        // 500-1500ms apart. 500ms was catching mid-burst and triggering rebuilds
        // against intermediate states. 750ms coalesces bursts reliably without
        // adding perceptible recovery lag (250ms difference is imperceptible).
        logger.info("Device change debouncing for 750ms to allow changes to settle")
        deviceChangeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000) // 750ms
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

        // If warmup is already in progress, skip — let the current warmup complete (Change 4)
        let currentState = engineState.withLock { $0 }
        if currentState == .warmingUp {
            logger.info("Skipping engine restart — warmup already in progress")
            return
        }

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

    // MARK: - CoreAudio HAL readiness (v0.3.11)
    //
    // Before calling AVAudioEngine() we poll the HAL for a default input device
    // that's (a) non-zero, (b) alive, and (c) has at least one input stream with
    // at least one channel. This closes the `kAudioHardwareBadDeviceError` (!dev
    // 560227702) race where the default device ID has become stale during a
    // device swap but CoreAudio hasn't finished reconfiguring the graph.
    //
    // Research: SimplyCoreAudio (https://github.com/rnine/SimplyCoreAudio) and
    // SFBAudioEngine's AudioDevice class implement the canonical version of this
    // check. osstatus.com confirms 560227702 = kAudioHardwareBadDeviceError.
    // https://www.osstatus.com/search/results?platform=all&framework=all&search=560227702

    /// Returns the current default input device ID, or nil if none is set.
    private nonisolated func getDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Queries `kAudioDevicePropertyDeviceIsAlive` on the given device.
    /// Returns true if the HAL reports the device as alive and usable.
    private nonisolated func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive == 1
    }

    /// Queries `kAudioDevicePropertyStreamConfiguration` (input scope) on the given device.
    /// Returns true if the device has at least one input stream with at least one channel.
    private nonisolated func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard dataStatus == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    /// Waits for the default input device to be in a valid, alive, streaming state.
    /// Polls every 75ms up to `timeout` seconds. Returns the valid AudioDeviceID
    /// or nil on timeout. This runs `nonisolated` / off the MainActor because
    /// the underlying AudioObjectGetPropertyData calls can block briefly during
    /// graph reconfiguration — same reasoning as commit 539a750 that moved
    /// AVAudioEngine() creation off the MainActor.
    private nonisolated func waitForDefaultInputDeviceReady(timeout: TimeInterval = 1.5) async -> AudioDeviceID? {
        let pollIntervalNs: UInt64 = 75_000_000 // 75 ms
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let deviceID = getDefaultInputDeviceID(),
               isDeviceAlive(deviceID),
               hasInputStreams(deviceID) {
                return deviceID
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        return nil
    }

    /// Returns (deviceName, deviceUID) for the current default input device via CoreAudio.
    /// Used for diagnostics — makes it immediately visible in logs when the wrong device is selected.
    private nonisolated func getDefaultInputDeviceName() -> (name: String, uid: String)? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }

        func getStringProperty(_ selector: AudioObjectPropertySelector, from objectID: AudioObjectID) -> String? {
            var propAddress = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // Use optional CFString to avoid creating a throwaway object.
            // AudioObjectGetPropertyData writes a +1 retained CFStringRef into the buffer;
            // Swift ARC manages the returned reference automatically (toll-free bridged to NSString).
            var cfName: CFString?
            var propSize = UInt32(MemoryLayout<CFString?>.size)
            let status = withUnsafeMutablePointer(to: &cfName) { ptr -> OSStatus in
                AudioObjectGetPropertyData(objectID, &propAddress, 0, nil, &propSize, UnsafeMutableRawPointer(ptr))
            }
            guard status == noErr, let name = cfName else { return nil }
            return name as String
        }

        let name = getStringProperty(kAudioObjectPropertyName, from: deviceID) ?? "Unknown"
        let uid = getStringProperty(kAudioDevicePropertyDeviceUID, from: deviceID) ?? "Unknown"

        return (name: name, uid: uid)
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case formatCreationFailed
        case engineStartTimeout
        case engineBroken(String)
        case engineNotReady(String)
        /// v0.3.11: CoreAudio HAL preflight failed — default input device is not alive
        /// or has no input streams yet. Transient; should be retried via backoff ladder.
        case deviceNotReady(String)

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
            case .deviceNotReady(let reason):
                return "Default input device not ready: \(reason)"
            }
        }

        /// True for errors that should route into the recovery backoff ladder instead
        /// of transitioning the engine state to `.broken`. Added in v0.3.11 to stop
        /// mis-classifying transient CoreAudio HAL races as terminal failures.
        var isTransient: Bool {
            switch self {
            case .deviceNotReady, .engineStartTimeout:
                return true
            case .engineBroken(let reason):
                // "Stale format during warmup" from v0.3.10 is also transient — the graph
                // was mid-reconfig when we queried it. Retry via the ladder.
                return reason.contains("Stale format") || reason.contains("No audio buffers")
            default:
                return false
            }
        }
    }
}
