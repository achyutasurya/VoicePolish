import XCTest
@testable import VoicePolish

final class TextInsertionServiceTests: XCTestCase {
    func testNormalizeCitrixTypingTextConvertsAllCRVariantsToLF() {
        let input = "line1\rline2\r\nline3\nline4"
        let output = TextInsertionService.normalizeCitrixTypingText(input)

        XCTAssertEqual(output, "line1\nline2\nline3\nline4")
    }

    func testMakeCitrixTypingChunksUsesConfiguredChunkSize() {
        let input = "abcdefghij"
        let chunks = TextInsertionService.makeCitrixTypingChunks(from: input, chunkSize: 4)

        XCTAssertEqual(chunks.map(String.init), ["abcd", "efgh", "ij"])
    }

    func testMakeCitrixTypingChunksClampsInvalidChunkSize() {
        let input = "abc"
        let chunks = TextInsertionService.makeCitrixTypingChunks(from: input, chunkSize: 0)

        XCTAssertEqual(chunks.map(String.init), ["a", "b", "c"])
    }

    func testNextDelayForSpaceUsesConfiguredRange() {
        for _ in 0..<100 {
            let delay = TextInsertionService.nextDelayMsForCitrixCharacter(
                " ",
                interKeyDelayMs: 90,
                newlineDelayMs: 220,
                wordPauseMinMs: 500,
                wordPauseMaxMs: 1_000,
                charJitterMs: 25
            )
            XCTAssertGreaterThanOrEqual(delay, 500)
            XCTAssertLessThanOrEqual(delay, 1_000)
        }
    }

    func testNextDelayForCharacterUsesJitterRange() {
        for _ in 0..<100 {
            let delay = TextInsertionService.nextDelayMsForCitrixCharacter(
                "a",
                interKeyDelayMs: 90,
                newlineDelayMs: 220,
                wordPauseMinMs: 500,
                wordPauseMaxMs: 1_000,
                charJitterMs: 25
            )
            XCTAssertGreaterThanOrEqual(delay, 65)
            XCTAssertLessThanOrEqual(delay, 115)
        }
    }
}
