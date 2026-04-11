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

    func transcribeAudio(wavData: Data, apiKey: String, model: String,
                         keyterms: [String] = [],
                         vocabularyEnabled: Bool = false) async throws -> String {
        var urlString = "\(baseURL)/listen?model=\(model)&smart_format=true"

        if vocabularyEnabled && !keyterms.isEmpty {
            // Character set for encoding query parameter VALUES (not full query strings).
            // .urlQueryAllowed leaves :+&= unencoded since they're structural in URLs,
            // but they must be encoded inside values to avoid corrupting the URL.
            var paramValueAllowed = CharacterSet.urlQueryAllowed
            paramValueAllowed.remove(charactersIn: ":+&=")

            // Append keyterms or keywords based on model
            let usesKeyterm = model.hasPrefix("nova-3") // nova-3, nova-3-general, nova-3-flux
            for term in keyterms where !term.isEmpty {
                let encoded = term.addingPercentEncoding(withAllowedCharacters: paramValueAllowed) ?? term
                if usesKeyterm {
                    urlString += "&keyterm=\(encoded)"
                } else {
                    urlString += "&keywords=\(encoded)"
                }
            }
        }
        guard let url = URL(string: urlString) else {
            throw DeepgramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        request.timeoutInterval = 30

        logger.info("Sending audio to Deepgram. Model: \(model), Size: \(wavData.count) bytes, URL: \(urlString)")

        let startTime = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await URLSession.shared.data(for: request)
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.invalidResponse
        }

        let responseHeaders = httpResponse.allHeaderFields

        logger.apiCall(
            service: "Deepgram",
            endpoint: urlString,
            method: "POST",
            requestSize: wavData.count,
            statusCode: httpResponse.statusCode,
            responseSize: data.count,
            duration: duration,
            headers: responseHeaders
        )

        // Handle rate limiting with automatic retry
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "1"
            let waitSeconds = Double(retryAfter) ?? 1.0
            logger.info("Deepgram rate limited. Retrying after \(String(format: "%.1f", waitSeconds))s")

            try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))

            // Retry the request recursively (max 1 retry to avoid infinite loops)
            do {
                return try await transcribeAudio(wavData: wavData, apiKey: apiKey, model: model,
                                                   keyterms: keyterms,
                                                   vocabularyEnabled: vocabularyEnabled)
            } catch DeepgramError.apiError(let code, _) where code == 429 {
                // Rate limited again, give up
                throw DeepgramError.apiError(statusCode: 429, message: "Rate limited: too many requests")
            }
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.apiCall(
                service: "Deepgram",
                endpoint: urlString,
                method: "POST",
                requestSize: wavData.count,
                statusCode: httpResponse.statusCode,
                responseSize: data.count,
                duration: duration,
                headers: responseHeaders,
                error: errorBody
            )
            throw DeepgramError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)

        // Observability: log every Deepgram response (success or empty) with the fields
        // that let us distinguish silent-mic from clip-too-short from Deepgram glitch.
        // Added in v0.3.8 to unblock threshold tuning for later commits. See plan file
        // abstract-rolling-babbage.md Commit 1.
        let metaDuration = decoded.metadata?.duration ?? 0
        let metaRequestId = decoded.metadata?.requestId ?? "-"
        let firstAlt = decoded.results?.channels.first?.alternatives.first
        let altConfidence = firstAlt?.confidence ?? 0
        let altWordCount = firstAlt?.words?.count ?? 0
        logger.info("[Deepgram] request_id=\(metaRequestId) duration=\(String(format: "%.2f", metaDuration)) confidence=\(String(format: "%.3f", altConfidence)) wordCount=\(altWordCount)")

        guard let transcript = firstAlt?.transcript, !transcript.isEmpty else {
            throw DeepgramError.emptyTranscript
        }

        logger.info("Deepgram transcription received (\(transcript.count) chars)")
        return transcript
    }

    // MARK: - Response Types

    struct DeepgramResponse: Codable {
        let metadata: Metadata?
        let results: Results?

        struct Metadata: Codable {
            let duration: Double
            let requestId: String?

            enum CodingKeys: String, CodingKey {
                case duration
                case requestId = "request_id"
            }
        }

        struct Results: Codable {
            let channels: [Channel]
        }

        struct Channel: Codable {
            let alternatives: [Alternative]
        }

        struct Alternative: Codable {
            let transcript: String
            let confidence: Double
            let words: [Word]?
        }

        struct Word: Codable {
            let word: String
            let start: Double
            let end: Double
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
