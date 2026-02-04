import XCTest
@testable import VoicePolish

final class RecordingPipelineTests: XCTestCase {
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

    // MARK: - Recording State Transitions

    func testRecordingStateTransitions() {
        // Start: idle
        XCTAssertEqual(audioRecorder.state, .idle)

        // Simulate recording start (without actual audio engine)
        audioRecorder.state = .recording
        audioRecorder.startTime = Date()
        XCTAssertEqual(audioRecorder.state, .recording)

        // Pause
        audioRecorder.pauseRecording()
        XCTAssertEqual(audioRecorder.state, .paused)

        // Resume
        do {
            try audioRecorder.resumeRecording()
            XCTAssertEqual(audioRecorder.state, .recording)
        } catch {
            XCTFail("Resume should not throw: \(error)")
        }

        // Stop
        audioRecorder.stopRecording()
        XCTAssertEqual(audioRecorder.state, .idle)
    }

    func testRecordingWithPauseAndResume() {
        audioRecorder.state = .recording
        audioRecorder.startTime = Date(timeIntervalSinceNow: -2.0)
        audioRecorder.accumulatedTime = 0

        let beforePause = audioRecorder.recordingDuration

        audioRecorder.pauseRecording()
        XCTAssertEqual(audioRecorder.state, .paused)

        // Duration accumulated
        let afterPause = audioRecorder.recordingDuration
        XCTAssertGreater(afterPause, beforePause)

        do {
            try audioRecorder.resumeRecording()
            XCTAssertEqual(audioRecorder.state, .recording)
        } catch {
            XCTFail("Resume should not throw: \(error)")
        }
    }

    func testRecordingCancellation() {
        audioRecorder.state = .recording
        audioRecorder.startTime = Date()
        audioRecorder.recordingDuration = 5.0

        audioRecorder.cancelRecording()

        XCTAssertEqual(audioRecorder.state, .idle, "State should be idle after cancel")
        XCTAssertEqual(audioRecorder.recordingDuration, 0, "Duration should be reset")
    }

    // MARK: - Audio Data Lifecycle

    func testAudioDataRetrieval() {
        let data = audioRecorder.getAudioData()
        XCTAssertNil(data, "Should return nil when no audio file exists")
    }

    // MARK: - Duration Accumulation

    func testDurationAccumulationOverMultiplePausedSegments() {
        // First segment
        audioRecorder.state = .recording
        audioRecorder.startTime = Date(timeIntervalSinceNow: -1.0)

        audioRecorder.pauseRecording()
        let firstSegmentDuration = audioRecorder.recordingDuration
        XCTAssertGreater(firstSegmentDuration, 0)

        // Second segment
        do {
            try audioRecorder.resumeRecording()
            audioRecorder.startTime = Date(timeIntervalSinceNow: -1.5)

            audioRecorder.pauseRecording()
            let secondSegmentDuration = audioRecorder.recordingDuration
            XCTAssertGreater(secondSegmentDuration, firstSegmentDuration, "Duration should continue accumulating")
        } catch {
            XCTFail("Resume should not throw: \(error)")
        }
    }

    // MARK: - State Validation

    func testCannotResumeFromRecording() throws {
        audioRecorder.state = .recording

        XCTAssertThrowsError(try audioRecorder.resumeRecording())
    }

    func testCannotResumeFromIdle() throws {
        audioRecorder.state = .idle

        XCTAssertThrowsError(try audioRecorder.resumeRecording())
    }

    // MARK: - Audio Level Tracking

    func testAudioLevelResetOnStop() {
        audioRecorder.state = .recording
        audioRecorder.audioLevel = 0.5

        audioRecorder.stopRecording()

        XCTAssertEqual(audioRecorder.audioLevel, 0, "Audio level should be reset")
    }

    func testAudioLevelResetOnCancel() {
        audioRecorder.state = .recording
        audioRecorder.audioLevel = 0.8

        audioRecorder.cancelRecording()

        XCTAssertEqual(audioRecorder.audioLevel, 0, "Audio level should be reset")
    }

    // MARK: - Multiple Recording Sessions

    func testMultipleRecordingSessions() {
        // First session
        audioRecorder.state = .recording
        audioRecorder.startTime = Date()
        audioRecorder.pauseRecording()
        let firstDuration = audioRecorder.recordingDuration

        audioRecorder.stopRecording()
        XCTAssertEqual(audioRecorder.state, .idle)

        // Second session
        audioRecorder.state = .recording
        audioRecorder.startTime = Date(timeIntervalSinceNow: -1.0)
        audioRecorder.pauseRecording()
        let secondDuration = audioRecorder.recordingDuration

        // Both sessions have independent durations
        XCTAssertGreater(secondDuration, 0)
    }
}
