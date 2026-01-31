import Foundation

actor DeepgramService {
    private let baseURL = "https://api.deepgram.com/v1"
    private let logger = LoggingService.shared

    // MARK: - API Key Verification

    func verifyAPIKey(_ settings: AppSettings) async {
        let apiKey = await MainActor.run { settings.deepgramAPIKey }
        let url = URL(string: "\(baseURL)/auth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    settings.isDeepgramKeyValid = false
                    settings.deepgramKeyError = "Invalid response"
                }
                return
            }

            if httpResponse.statusCode == 200 {
                await MainActor.run {
                    settings.isDeepgramKeyValid = true
                    settings.deepgramKeyError = ""
                }
                logger.info("Deepgram API key verified successfully")
            } else {
                await MainActor.run {
                    settings.isDeepgramKeyValid = false
                    settings.deepgramKeyError = "Invalid API key (HTTP \(httpResponse.statusCode))"
                }
                logger.error("Deepgram API key verification failed: HTTP \(httpResponse.statusCode)")
            }
        } catch {
            await MainActor.run {
                settings.isDeepgramKeyValid = false
                settings.deepgramKeyError = "Network error: \(error.localizedDescription)"
            }
            logger.error("Deepgram API key verification error: \(error)")
        }
    }

    // MARK: - Transcribe Audio

    func transcribeAudio(wavData: Data, apiKey: String, model: String) async throws -> String {
        let urlString = "\(baseURL)/listen?model=\(model)&smart_format=true"
        guard let url = URL(string: urlString) else {
            throw DeepgramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        request.timeoutInterval = 30

        logger.info("Sending audio to Deepgram. Model: \(model), Size: \(wavData.count) bytes")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.invalidResponse
        }

        logger.info("Deepgram response: HTTP \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Deepgram error: \(errorBody)")
            throw DeepgramError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)

        guard let transcript = decoded.results?.channels.first?.alternatives.first?.transcript,
              !transcript.isEmpty else {
            throw DeepgramError.emptyTranscript
        }

        logger.info("Deepgram transcription received (\(transcript.count) chars)")
        return transcript
    }

    // MARK: - Response Types

    struct DeepgramResponse: Codable {
        let results: Results?

        struct Results: Codable {
            let channels: [Channel]
        }

        struct Channel: Codable {
            let alternatives: [Alternative]
        }

        struct Alternative: Codable {
            let transcript: String
            let confidence: Double
        }
    }

    enum DeepgramError: LocalizedError {
        case invalidURL
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Deepgram URL"
            case .invalidResponse: return "Invalid response from Deepgram"
            case .apiError(let code, let msg): return "Deepgram error (\(code)): \(msg)"
            case .emptyTranscript: return "No speech detected in audio"
            }
        }
    }
}
