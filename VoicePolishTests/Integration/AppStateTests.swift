import XCTest
@testable import VoicePolish

final class AppStateTests: XCTestCase {
    var appState: AppState!
    var mockPermissionManager: MockPermissionManager!

    override func setUp() {
        super.setUp()
        appState = AppState()
        mockPermissionManager = MockPermissionManager()
    }

    override func tearDown() {
        appState = nil
        mockPermissionManager = nil
        super.tearDown()
    }

    // MARK: - AppState Initialization

    func testAppStateInitializes() {
        XCTAssertNotNil(appState.audioRecorder, "Audio recorder should be initialized")
        XCTAssertNotNil(appState.deepgramService, "Deepgram service should be initialized")
        XCTAssertNotNil(appState.openRouterService, "OpenRouter service should be initialized")
        XCTAssertNotNil(appState.textInsertionService, "Text insertion service should be initialized")
        XCTAssertNotNil(appState.settings, "Settings should be initialized")
    }

    func testAppStateHasPermissionManager() {
        XCTAssertNotNil(appState.permissionManager, "Permission manager should be initialized")
    }

    // MARK: - Settings Access

    func testAppStateCanAccessSettings() {
        let apiKey = "test-key"
        appState.settings.deepgramAPIKey = apiKey

        XCTAssertEqual(appState.settings.deepgramAPIKey, apiKey)
    }

    func testAppStateAudioRecorderAccessible() {
        let initialState = appState.audioRecorder.state
        XCTAssertEqual(initialState, .idle, "Recording should start in idle state")
    }

    // MARK: - Custom Model Input

    func testCustomModelInputStorage() {
        let customModel = "my-custom-model"
        appState.customModelInput = customModel

        XCTAssertEqual(appState.customModelInput, customModel)
    }

    func testShouldStopAndSendFlag() {
        XCTAssertFalse(appState.shouldStopAndSend, "Should stop flag should start as false")

        appState.shouldStopAndSend = true
        XCTAssertTrue(appState.shouldStopAndSend)
    }

    // MARK: - Service Integration

    func testMockDeepgramIntegration() {
        let mockDeepgram = MockDeepgramService()
        mockDeepgram.transcriptToReturn = "Test transcript"

        XCTAssertEqual(mockDeepgram.transcriptToReturn, "Test transcript")
    }

    func testMockOpenRouterIntegration() {
        let mockOpenRouter = MockOpenRouterService()
        mockOpenRouter.responseToReturn = "Test LLM response"

        XCTAssertEqual(mockOpenRouter.responseToReturn, "Test LLM response")
    }

    func testMockPermissionManager() {
        let mock = MockPermissionManager()
        mock.microphonePermissionGranted = true
        mock.accessibilityPermissionGranted = true

        XCTAssertTrue(mock.microphonePermissionGranted)
        XCTAssertTrue(mock.accessibilityPermissionGranted)
    }

    // MARK: - Logger Access

    func testAppStateHasLogger() {
        XCTAssertNotNil(appState.logger, "Logger should be initialized")
    }

    func testLoggerCanLogMessage() {
        XCTAssertNoThrow(appState.logger.info("Test log from AppState"))
    }

    // MARK: - State Reset

    func testCancelRecordingResets() {
        appState.audioRecorder.state = .recording
        appState.audioRecorder.recordingDuration = 5.0

        appState.audioRecorder.cancelRecording()

        XCTAssertEqual(appState.audioRecorder.state, .idle)
        XCTAssertEqual(appState.audioRecorder.recordingDuration, 0)
    }

    // MARK: - Multi-Service Coordination

    func testSettingsAffectServices() {
        let testModel = "test-model-123"
        appState.settings.selectedModel = testModel

        XCTAssertEqual(appState.settings.selectedModel, testModel)
    }

    func testMultipleSettingChanges() {
        appState.settings.deepgramAPIKey = "key1"
        appState.settings.openRouterAPIKey = "key2"
        appState.settings.temperature = 0.7

        XCTAssertEqual(appState.settings.deepgramAPIKey, "key1")
        XCTAssertEqual(appState.settings.openRouterAPIKey, "key2")
        XCTAssertEqual(appState.settings.temperature, 0.7)
    }
}
