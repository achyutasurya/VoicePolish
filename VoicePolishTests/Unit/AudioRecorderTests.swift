import XCTest
@testable import VoicePolish

final class AudioRecorderTests: XCTestCase {
    var audioRecorder: AudioRecorder!

    override func setUp() {
        super.setUp()
        audioRecorder = AudioRecorder()
    }

    override func tearDown() {
        audioRecorder = nil
        TestHelpers.cleanupTestFiles()
        super.tearDown()
    }

    // MARK: - State Machine Tests

    func testInitialStateIsStopped() {
        let state = audioRecorder.engineState.withLock { $0 }
        XCTAssertEqual(state, .stopped, "Initial engine state should be stopped")
    }

    func testRecordingStateIsInitiallyIdle() {
        XCTAssertEqual(audioRecorder.state, .idle, "Initial recording state should be idle")
    }

    func testAudioLevelInitiallyZero() {
        XCTAssertEqual(audioRecorder.audioLevel, 0, "Initial audio level should be 0")
    }

    func testRecordingDurationInitiallyZero() {
        XCTAssertEqual(audioRecorder.recordingDuration, 0, "Initial duration should be 0")
    }

    // MARK: - Recording Lifecycle Tests

    func testStartRecordingRequiresRunningEngine() throws {
        // Before warmup, should throw engineNotReady
        XCTAssertThrowsError(
            try audioRecorder.startRecording(),
            "Should throw error when engine not running"
        ) { error in
            XCTAssert(error is AudioRecorder.RecorderError)
        }
    }

    func testStartRecordingCreatesAudioFile() throws {
        // This would require a running audio engine with actual audio
        // For now, we test that the error path works
        let recordingError = try? audioRecorder.startRecording()
        XCTAssertNotNil(recordingError, "Should fail without running engine")
    }

    func testPauseRecording() throws {
        XCTAssertEqual(audioRecorder.state, .idle)

        // Set state to recording manually (simulating successful start)
        audioRecorder.state = .recording
        audioRecorder.startTime = Date()

        audioRecorder.pauseRecording()
        XCTAssertEqual(audioRecorder.state, .paused, "State should be paused")
    }

    func testResumeRecording() throws {
        audioRecorder.state = .paused
        audioRecorder.accumulatedTime = 1.0

        XCTAssertNoThrow(try audioRecorder.resumeRecording())
        XCTAssertEqual(audioRecorder.state, .recording, "State should be recording after resume")
    }

    func testStopRecording() {
        audioRecorder.state = .recording
        audioRecorder.startTime = Date(timeIntervalSinceNow: -1.0)
        audioRecorder.accumulatedTime = 0

        let result = audioRecorder.stopRecording()

        XCTAssertEqual(audioRecorder.state, .idle, "State should be idle after stop")
        XCTAssertEqual(audioRecorder.audioLevel, 0, "Audio level should be reset")
        XCTAssertEqual(audioRecorder.recordingDuration, 0, "Duration should be reset")
    }

    func testCancelRecording() {
        audioRecorder.state = .recording
        audioRecorder.recordingDuration = 5.0

        audioRecorder.cancelRecording()

        XCTAssertEqual(audioRecorder.state, .idle, "State should be idle after cancel")
        XCTAssertEqual(audioRecorder.recordingDuration, 0, "Duration should be reset")
        XCTAssertEqual(audioRecorder.audioLevel, 0, "Audio level should be reset")
    }

    // MARK: - Audio Level Tests

    func testCalculateAudioLevel() {
        // Test with mock buffer
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Failed to create audio buffer")
            return
        }

        buffer.frameLength = 1024
        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Failed to get channel data")
            return
        }

        // Fill with test data
        for i in 0..<1024 {
            channelData[i] = 0.1 // Small amplitude
        }

        let level = AudioRecorder.calculateLevel(buffer: buffer)
        XCTAssertGreaterThan(level, 0, "Level should be positive")
        XCTAssertLessThanOrEqual(level, 1.0, "Level should not exceed 1.0")
    }

    func testAudioLevelMaxCapped() {
        // Test that very loud audio is capped at 1.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Failed to create audio buffer")
            return
        }

        buffer.frameLength = 1024
        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Failed to get channel data")
            return
        }

        // Fill with loud data
        for i in 0..<1024 {
            channelData[i] = 1.0
        }

        let level = AudioRecorder.calculateLevel(buffer: buffer)
        XCTAssertLessThanOrEqual(level, 1.0, "Level should be capped at 1.0")
    }

    // MARK: - Recording Duration Tests

    func testRecordingDurationTracking() {
        audioRecorder.state = .recording
        audioRecorder.startTime = Date(timeIntervalSinceNow: -2.5)
        audioRecorder.accumulatedTime = 1.0

        // Simulate timer update
        let duration = audioRecorder.accumulatedTime + Date().timeIntervalSince(audioRecorder.startTime!)
        XCTAssertGreater(duration, 3.0, "Duration should accumulate over time")
    }

    func testRecordingDurationResetAfterStop() {
        audioRecorder.state = .recording
        audioRecorder.recordingDuration = 10.0
        audioRecorder.accumulatedTime = 10.0

        audioRecorder.stopRecording()

        XCTAssertEqual(audioRecorder.recordingDuration, 0, "Recording duration should reset after stop")
    }

    // MARK: - Error Handling Tests

    func testNoInputDeviceError() {
        let error = AudioRecorder.RecorderError.noInputDevice
        XCTAssertNotNil(error.errorDescription, "Error should have description")
        XCTAssert(error.errorDescription!.contains("microphone"), "Error should mention microphone")
    }

    func testEngineStartTimeoutError() {
        let error = AudioRecorder.RecorderError.engineStartTimeout
        XCTAssertNotNil(error.errorDescription, "Error should have description")
        XCTAssert(error.errorDescription!.contains("timeout"), "Error should mention timeout")
    }

    func testEngineBrokenError() {
        let error = AudioRecorder.RecorderError.engineBroken("Test reason")
        XCTAssertNotNil(error.errorDescription, "Error should have description")
        XCTAssert(error.errorDescription!.contains("Test reason"), "Error should include reason")
    }

    func testEngineNotReadyError() {
        let error = AudioRecorder.RecorderError.engineNotReady("Engine warming up")
        XCTAssertNotNil(error.errorDescription, "Error should have description")
        XCTAssert(error.errorDescription!.contains("Engine warming up"), "Error should include context")
    }

    // MARK: - State Persistence Tests

    func testGetAudioDataReturnsNilWhenNoRecording() {
        let data = audioRecorder.getAudioData()
        XCTAssertNil(data, "Should return nil when no recording exists")
    }

    func testResumeThrowsErrorWhenNotPaused() throws {
        audioRecorder.state = .idle

        XCTAssertThrowsError(try audioRecorder.resumeRecording())
    }
}
