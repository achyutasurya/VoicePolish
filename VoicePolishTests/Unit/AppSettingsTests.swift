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

    // MARK: - Citrix Typing Settings Tests

    func testDefaultCitrixTypingSettings() {
        UserDefaults.standard.removeObject(forKey: "citrixTypingSpeedPreset")
        UserDefaults.standard.removeObject(forKey: "citrixTypingInterKeyDelayMs")
        UserDefaults.standard.removeObject(forKey: "citrixTypingNewlineDelayMs")
        UserDefaults.standard.removeObject(forKey: "citrixTypingChunkSize")
        UserDefaults.standard.removeObject(forKey: "citrixTypingChunkPauseMs")
        UserDefaults.standard.removeObject(forKey: "citrixTypingWordPauseMinMs")
        UserDefaults.standard.removeObject(forKey: "citrixTypingWordPauseMaxMs")
        UserDefaults.standard.removeObject(forKey: "citrixTypingCharJitterMs")

        XCTAssertEqual(settings.citrixTypingSpeedPreset, .wpm50, "Default preset should be 50 words/min")
        XCTAssertEqual(settings.citrixTypingInterKeyDelayMs, 90, "50 wpm inter-key delay should be 90ms")
        XCTAssertEqual(settings.citrixTypingNewlineDelayMs, 220, "50 wpm newline delay should be 220ms")
        XCTAssertEqual(settings.citrixTypingChunkSize, 40, "50 wpm chunk size should be 40")
        XCTAssertEqual(settings.citrixTypingChunkPauseMs, 350, "50 wpm chunk pause should be 350ms")
        XCTAssertEqual(settings.citrixTypingWordPauseMinMs, 500, "Default word pause min should be 500ms")
        XCTAssertEqual(settings.citrixTypingWordPauseMaxMs, 1_000, "Default word pause max should be 1000ms")
        XCTAssertEqual(settings.citrixTypingCharJitterMs, 25, "Default jitter should be 25ms")
    }

    func testSaveAndLoadCitrixTypingSettings() {
        settings.citrixTypingInterKeyDelayMs = 8
        settings.citrixTypingNewlineDelayMs = 20
        settings.citrixTypingChunkSize = 300
        settings.citrixTypingChunkPauseMs = 75
        settings.citrixTypingWordPauseMinMs = 550
        settings.citrixTypingWordPauseMaxMs = 900
        settings.citrixTypingCharJitterMs = 10

        let loaded = AppSettings.shared
        XCTAssertEqual(loaded.citrixTypingInterKeyDelayMs, 8)
        XCTAssertEqual(loaded.citrixTypingNewlineDelayMs, 20)
        XCTAssertEqual(loaded.citrixTypingChunkSize, 300)
        XCTAssertEqual(loaded.citrixTypingChunkPauseMs, 75)
        XCTAssertEqual(loaded.citrixTypingWordPauseMinMs, 550)
        XCTAssertEqual(loaded.citrixTypingWordPauseMaxMs, 900)
        XCTAssertEqual(loaded.citrixTypingCharJitterMs, 10)
    }

    func testCitrixTypingPresetApplies50WpmTimings() {
        settings.citrixTypingSpeedPreset = .wpm50

        XCTAssertEqual(settings.citrixTypingInterKeyDelayMs, 90)
        XCTAssertEqual(settings.citrixTypingNewlineDelayMs, 220)
        XCTAssertEqual(settings.citrixTypingChunkSize, 40)
        XCTAssertEqual(settings.citrixTypingChunkPauseMs, 350)
        XCTAssertEqual(settings.citrixTypingWordPauseMinMs, 500)
        XCTAssertEqual(settings.citrixTypingWordPauseMaxMs, 1_000)
        XCTAssertEqual(settings.citrixTypingCharJitterMs, 25)
    }

    func testCitrixTypingPresetApplies80WpmTimings() {
        settings.citrixTypingSpeedPreset = .wpm80

        XCTAssertEqual(settings.citrixTypingInterKeyDelayMs, 50)
        XCTAssertEqual(settings.citrixTypingNewlineDelayMs, 170)
        XCTAssertEqual(settings.citrixTypingChunkSize, 80)
        XCTAssertEqual(settings.citrixTypingChunkPauseMs, 240)
        XCTAssertEqual(settings.citrixTypingWordPauseMinMs, 500)
        XCTAssertEqual(settings.citrixTypingWordPauseMaxMs, 1_000)
        XCTAssertEqual(settings.citrixTypingCharJitterMs, 25)
    }

    func testCitrixTypingPresetApplies120WpmTimings() {
        settings.citrixTypingSpeedPreset = .wpm120

        XCTAssertEqual(settings.citrixTypingInterKeyDelayMs, 20)
        XCTAssertEqual(settings.citrixTypingNewlineDelayMs, 120)
        XCTAssertEqual(settings.citrixTypingChunkSize, 120)
        XCTAssertEqual(settings.citrixTypingChunkPauseMs, 180)
        XCTAssertEqual(settings.citrixTypingWordPauseMinMs, 500)
        XCTAssertEqual(settings.citrixTypingWordPauseMaxMs, 1_000)
        XCTAssertEqual(settings.citrixTypingCharJitterMs, 25)
    }

    func testCitrixTypingPresetInfersFromExistingTiming() {
        UserDefaults.standard.removeObject(forKey: "citrixTypingSpeedPreset")
        UserDefaults.standard.set(90, forKey: "citrixTypingInterKeyDelayMs")

        XCTAssertEqual(settings.citrixTypingSpeedPreset, .wpm50)
        XCTAssertEqual(settings.citrixTypingInterKeyDelayMs, 90, "Existing timing should be preserved during inference")
    }

    func testCitrixTypingSettingsClampInvalidValues() {
        settings.citrixTypingInterKeyDelayMs = -1
        settings.citrixTypingNewlineDelayMs = -5
        settings.citrixTypingChunkSize = 0
        settings.citrixTypingChunkPauseMs = -10
        settings.citrixTypingWordPauseMinMs = -1
        settings.citrixTypingWordPauseMaxMs = -1
        settings.citrixTypingCharJitterMs = -10

        let loaded = AppSettings.shared
        XCTAssertEqual(loaded.citrixTypingInterKeyDelayMs, 90, "Invalid inter-key delay should fall back to default")
        XCTAssertEqual(loaded.citrixTypingNewlineDelayMs, 220, "Invalid newline delay should fall back to default")
        XCTAssertEqual(loaded.citrixTypingChunkSize, 1, "Chunk size should clamp to 1")
        XCTAssertEqual(loaded.citrixTypingChunkPauseMs, 350, "Invalid chunk pause should fall back to default")
        XCTAssertEqual(loaded.citrixTypingWordPauseMinMs, 0, "Word pause min should clamp to 0")
        XCTAssertEqual(loaded.citrixTypingWordPauseMaxMs, 0, "Word pause max should clamp to min")
        XCTAssertEqual(loaded.citrixTypingCharJitterMs, 0, "Jitter should clamp to 0")
    }
}
