import Foundation

actor OpenRouterService {
    private let baseURL = "https://openrouter.ai/api/v1"
    private let logger = LoggingService.shared

    // MARK: - API Key Verification

    func verifyAPIKey(_ settings: AppSettings) async {
        let apiKey = await MainActor.run { settings.openRouterAPIKey }
        let url = URL(string: "\(baseURL)/auth/key")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    settings.isOpenRouterKeyValid = false
                    settings.openRouterKeyError = "Invalid response"
                }
                return
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataObj = json["data"] as? [String: Any] {
                    let limit = dataObj["limit"] as? Double
                    let usage = dataObj["usage"] as? Double

                    let credits: String
                    if let limit, let usage {
                        credits = String(format: "$%.2f remaining of $%.2f", limit - usage, limit)
                    } else if let usage {
                        credits = String(format: "Used: $%.2f (unlimited)", usage)
                    } else {
                        credits = "Valid"
                    }

                    await MainActor.run {
                        settings.isOpenRouterKeyValid = true
                        settings.openRouterKeyCredits = credits
                        settings.openRouterKeyError = ""
                    }
                } else {
                    await MainActor.run {
                        settings.isOpenRouterKeyValid = true
                        settings.openRouterKeyCredits = "Valid"
                        settings.openRouterKeyError = ""
                    }
                }
                logger.info("OpenRouter API key verified successfully")
            } else {
                await MainActor.run {
                    settings.isOpenRouterKeyValid = false
                    settings.openRouterKeyError = "Invalid API key (HTTP \(httpResponse.statusCode))"
                }
                logger.error("OpenRouter API key verification failed: HTTP \(httpResponse.statusCode)")
            }
        } catch {
            await MainActor.run {
                settings.isOpenRouterKeyValid = false
                settings.openRouterKeyError = "Network error: \(error.localizedDescription)"
            }
            logger.error("OpenRouter API key verification error: \(error)")
        }
    }

    // MARK: - Verify Model

    /// Check if a model ID is valid by sending a minimal test request.
    /// Returns nil on success, or an error message string on failure.
    func verifyModel(modelId: String, apiKey: String) async -> String? {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/voicepolish", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("VoicePolish", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": modelId,
            "max_tokens": 1,
            "messages": [
                ["role": "system", "content": "Reply with ok."],
                ["role": "user", "content": "hi"],
            ],
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return "Invalid response"
            }

            if httpResponse.statusCode == 200 {
                logger.info("Model \(modelId) verified successfully")
                return nil // success
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                // Parse the error message from JSON if possible
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    logger.error("Model verification failed: \(message)")
                    return message
                }
                logger.error("Model verification failed: \(errorBody)")
                return "HTTP \(httpResponse.statusCode)"
            }
        } catch {
            logger.error("Model verification error: \(error)")
            return error.localizedDescription
        }
    }

    // MARK: - Process Text

    func processText(transcript: String, systemPrompt: String, model: String, apiKey: String, temperature: Double = 0.3) async throws -> String {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/voicepolish", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("VoicePolish", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("Sending transcript to OpenRouter. Model: \(model), Length: \(transcript.count) chars")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }

        logger.info("OpenRouter response: HTTP \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("OpenRouter error: \(errorBody)")
            throw OpenRouterError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        if let error = decoded.error {
            throw OpenRouterError.apiError(statusCode: httpResponse.statusCode, message: error.message)
        }

        guard let text = decoded.choices?.first?.message.content, !text.isEmpty else {
            throw OpenRouterError.emptyResponse
        }

        logger.info("OpenRouter response received (\(text.count) chars)")
        return text
    }

    // MARK: - Response Types

    struct ChatCompletionResponse: Codable {
        let choices: [Choice]?
        let error: ErrorResponse?

        struct Choice: Codable {
            let message: Message
        }

        struct Message: Codable {
            let content: String?
        }

        struct ErrorResponse: Codable {
            let message: String
            let code: Int?
        }
    }

    enum OpenRouterError: LocalizedError {
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from OpenRouter"
            case .apiError(let code, let msg): return "OpenRouter error (\(code)): \(msg)"
            case .emptyResponse: return "Empty response from model"
            }
        }
    }
}
