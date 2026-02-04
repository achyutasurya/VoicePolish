import XCTest
@testable import VoicePolish

final class AppSettingsTests: XCTestCase {
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // Use test UserDefaults domain
        UserDefaults().removePersistentDomain(forName: "com.voicepolish.test")
        settings = AppSettings.shared
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: "com.voicepolish.test")
        super.tearDown()
    }

    // MARK: - API Key Tests

    func testDefaultDeepgramKeyIsEmpty() {
        XCTAssertEqual(settings.deepgramAPIKey, "", "Default Deepgram key should be empty")
    }

    func testDefaultOpenRouterKeyIsEmpty() {
        XCTAssertEqual(settings.openRouterAPIKey, "", "Default OpenRouter key should be empty")
    }

    func testSaveAndLoadDeepgramKey() {
        let testKey = "test-deepgram-key-12345"
        settings.deepgramAPIKey = testKey

        let loaded = AppSettings.shared.deepgramAPIKey
        XCTAssertEqual(loaded, testKey, "Deepgram key should persist")
    }

    func testSaveAndLoadOpenRouterKey() {
        let testKey = "test-openrouter-key-12345"
        settings.openRouterAPIKey = testKey

        let loaded = AppSettings.shared.openRouterAPIKey
        XCTAssertEqual(loaded, testKey, "OpenRouter key should persist")
    }

    // MARK: - Model Selection Tests

    func testDefaultModelIsSet() {
        XCTAssertFalse(settings.selectedModel.isEmpty, "Default model should be set")
    }

    func testSaveAndLoadSelectedModel() {
        let testModel = "openai/gpt-4o"
        settings.selectedModel = testModel

        let loaded = AppSettings.shared.selectedModel
        XCTAssertEqual(loaded, testModel, "Selected model should persist")
    }

    func testDefaultDeepgramModelIsSet() {
        XCTAssertFalse(settings.deepgramModel.isEmpty, "Default Deepgram model should be set")
    }

    // MARK: - Temperature Tests

    func testDefaultTemperatureIsReasonable() {
        XCTAssertGreaterThanOrEqual(settings.temperature, 0.0, "Temperature should be >= 0")
        XCTAssertLessThanOrEqual(settings.temperature, 2.0, "Temperature should be <= 2.0")
    }

    func testTemperatureCanBeSet() {
        settings.temperature = 0.5
        let loaded = AppSettings.shared.temperature
        XCTAssertEqual(loaded, 0.5, "Temperature should persist")
    }

    func testTemperatureExtremes() {
        settings.temperature = 0.0
        XCTAssertEqual(AppSettings.shared.temperature, 0.0, "Should accept temperature 0.0")

        settings.temperature = 2.0
        XCTAssertEqual(AppSettings.shared.temperature, 2.0, "Should accept temperature 2.0")
    }

    // MARK: - System Prompt Tests

    func testDefaultSystemPromptIsSet() {
        XCTAssertFalse(settings.systemPrompt.isEmpty, "Default system prompt should be set")
    }

    func testSaveAndLoadSystemPrompt() {
        let testPrompt = "You are a helpful assistant that responds in 1-2 sentences."
        settings.systemPrompt = testPrompt

        let loaded = AppSettings.shared.systemPrompt
        XCTAssertEqual(loaded, testPrompt, "System prompt should persist")
    }

    func testLongSystemPrompt() {
        let longPrompt = String(repeating: "This is a long prompt. ", count: 100)
        settings.systemPrompt = longPrompt

        let loaded = AppSettings.shared.systemPrompt
        XCTAssertEqual(loaded, longPrompt, "Long system prompt should persist")
    }

    // MARK: - Popup Position Tests

    func testDefaultPopupPositionIsZero() {
        XCTAssertEqual(settings.popupX, 0, "Default popup X should be 0")
        XCTAssertEqual(settings.popupY, 0, "Default popup Y should be 0")
    }

    func testSaveAndLoadPopupPosition() {
        settings.popupX = 100
        settings.popupY = 200

        let loadedX = AppSettings.shared.popupX
        let loadedY = AppSettings.shared.popupY

        XCTAssertEqual(loadedX, 100, "Popup X position should persist")
        XCTAssertEqual(loadedY, 200, "Popup Y position should persist")
    }

    func testMultipleSettingsPersistIndependently() {
        settings.deepgramAPIKey = "key1"
        settings.openRouterAPIKey = "key2"
        settings.temperature = 0.7
        settings.selectedModel = "test-model"

        let loaded = AppSettings.shared

        XCTAssertEqual(loaded.deepgramAPIKey, "key1")
        XCTAssertEqual(loaded.openRouterAPIKey, "key2")
        XCTAssertEqual(loaded.temperature, 0.7)
        XCTAssertEqual(loaded.selectedModel, "test-model")
    }

    func testSettingsUpdateIndependently() {
        settings.temperature = 0.5
        XCTAssertEqual(AppSettings.shared.temperature, 0.5)

        settings.temperature = 1.0
        XCTAssertEqual(AppSettings.shared.temperature, 1.0, "Temperature should update independently")

        // Other settings shouldn't change
        settings.deepgramAPIKey = "new-key"
        XCTAssertEqual(AppSettings.shared.temperature, 1.0, "Temperature should remain unchanged")
    }
}
