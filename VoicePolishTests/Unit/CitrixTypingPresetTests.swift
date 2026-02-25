import XCTest
@testable import VoicePolish

final class CitrixTypingPresetTests: XCTestCase {
    func test50WpmPresetValues() {
        let preset = AppSettings.CitrixTypingSpeedPreset.wpm50
        XCTAssertEqual(preset.interKeyDelayMs, 90)
        XCTAssertEqual(preset.newlineDelayMs, 220)
        XCTAssertEqual(preset.chunkSize, 40)
        XCTAssertEqual(preset.chunkPauseMs, 350)
        XCTAssertEqual(preset.wordPauseMinMs, 500)
        XCTAssertEqual(preset.wordPauseMaxMs, 1_000)
    }

    func test80WpmPresetValues() {
        let preset = AppSettings.CitrixTypingSpeedPreset.wpm80
        XCTAssertEqual(preset.interKeyDelayMs, 50)
        XCTAssertEqual(preset.newlineDelayMs, 170)
        XCTAssertEqual(preset.chunkSize, 80)
        XCTAssertEqual(preset.chunkPauseMs, 240)
        XCTAssertEqual(preset.wordPauseMinMs, 500)
        XCTAssertEqual(preset.wordPauseMaxMs, 1_000)
    }

    func test120WpmPresetValues() {
        let preset = AppSettings.CitrixTypingSpeedPreset.wpm120
        XCTAssertEqual(preset.interKeyDelayMs, 20)
        XCTAssertEqual(preset.newlineDelayMs, 120)
        XCTAssertEqual(preset.chunkSize, 120)
        XCTAssertEqual(preset.chunkPauseMs, 180)
        XCTAssertEqual(preset.wordPauseMinMs, 500)
        XCTAssertEqual(preset.wordPauseMaxMs, 1_000)
    }

    func testPresetInference() {
        XCTAssertEqual(AppSettings.CitrixTypingSpeedPreset.inferFrom(interKeyDelayMs: 1200), .wpm50)
        XCTAssertEqual(AppSettings.CitrixTypingSpeedPreset.inferFrom(interKeyDelayMs: 750), .wpm80)
        XCTAssertEqual(AppSettings.CitrixTypingSpeedPreset.inferFrom(interKeyDelayMs: 400), .wpm120)
        XCTAssertEqual(AppSettings.CitrixTypingSpeedPreset.inferFrom(interKeyDelayMs: 90), .wpm50)
        XCTAssertEqual(AppSettings.CitrixTypingSpeedPreset.inferFrom(interKeyDelayMs: 50), .wpm80)
        XCTAssertEqual(AppSettings.CitrixTypingSpeedPreset.inferFrom(interKeyDelayMs: 20), .wpm120)
    }
}
