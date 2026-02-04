import Foundation
@testable import VoicePolish

/// Mock Deepgram service for testing
class MockDeepgramService: DeepgramService {
    var transcriptToReturn: String = "test transcript"
    var shouldFail: Bool = false
    var lastAudioDataSize: Int = 0
    var callCount: Int = 0

    override func transcribeAudio(
        wavData: Data,
        apiKey: String,
        model: String
    ) async throws -> String {
        callCount += 1
        lastAudioDataSize = wavData.count

        if shouldFail {
            throw NSError(
                domain: "MockDeepgramService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock transcription failed"]
            )
        }

        return transcriptToReturn
    }

    func reset() {
        transcriptToReturn = "test transcript"
        shouldFail = false
        lastAudioDataSize = 0
        callCount = 0
    }
}

/// Mock OpenRouter service for testing
class MockOpenRouterService: OpenRouterService {
    var responseToReturn: String = "test response"
    var shouldFail: Bool = false
    var lastTranscript: String = ""
    var callCount: Int = 0

    override func processText(
        transcript: String,
        systemPrompt: String,
        model: String,
        apiKey: String,
        temperature: Double
    ) async throws -> String {
        callCount += 1
        lastTranscript = transcript

        if shouldFail {
            throw NSError(
                domain: "MockOpenRouterService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mock LLM failed"]
            )
        }

        return responseToReturn
    }

    func reset() {
        responseToReturn = "test response"
        shouldFail = false
        lastTranscript = ""
        callCount = 0
    }
}

/// Mock permission manager for testing
class MockPermissionManager: PermissionManager {
    var microphonePermissionGranted: Bool = true
    var accessibilityPermissionGranted: Bool = true
    var checkMicrophoneCalled: Bool = false
    var requestMicrophoneCalled: Bool = false

    override func checkMicrophonePermission() {
        checkMicrophoneCalled = true
    }

    override func checkAndRequestPermissions() {
        requestMicrophoneCalled = true
    }
}
