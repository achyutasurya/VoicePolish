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
                    ErrorService.shared.addError(
                        source: .deepgram, severity: .error,
                        message: "Deepgram API key invalid",
                        details: "HTTP \(httpResponse.statusCode)",
                        code: "deepgram.key_verification_failed"
                    )
                }
                logger.error("Deepgram API key verification failed: HTTP \(httpResponse.statusCode)")
            }
        } catch {
            await MainActor.run {
                settings.isDeepgramKeyValid = false
                settings.deepgramKeyError = "Network error: \(error.localizedDescription)"
                ErrorService.shared.addError(
                    source: .deepgram, severity: .error,
                    message: "Deepgram API key verification network error",
                    details: error.localizedDescription,
                    code: "deepgram.key_verification_network_error"
                )
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

        // Iterative retry with exponential backoff + jitter (v0.3.9).
        // Replaces the recursive 429 retry added in commit 8fbcc0d — that version
        // had no attempt cap, no exponential growth, and no jitter, which is exactly
        // the thundering-herd anti-pattern Deepgram's back-off article warns against.
        // Allowlist matches Deepgram's Python SDK default; max 3 retries (4 total requests).
        // Ref: https://deepgram.com/learn/api-back-off-strategies
        let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
        let maxRetries = 3

        var data = Data()
        var httpResponse: HTTPURLResponse?
        var rtt: TimeInterval = 0

        for attempt in 0...maxRetries {
            let startTime = CFAbsoluteTimeGetCurrent()
            let (responseData, urlResponse) = try await URLSession.shared.data(for: request)
            rtt = CFAbsoluteTimeGetCurrent() - startTime

            guard let resp = urlResponse as? HTTPURLResponse else {
                throw DeepgramError.invalidResponse
            }

            data = responseData
            httpResponse = resp

            logger.apiCall(
                service: "Deepgram",
                endpoint: urlString,
                method: "POST",
                requestSize: wavData.count,
                statusCode: resp.statusCode,
                responseSize: responseData.count,
                duration: rtt,
                headers: resp.allHeaderFields
            )

            // Retry only on allowlisted transient status codes AND only if we have attempts left.
            // 4xx-other (400/401/403/404) are permanent — never retry those.
            if retryableStatusCodes.contains(resp.statusCode) && attempt < maxRetries {
                // Honor Retry-After header (Deepgram sends it on 429 and may send on 5xx).
                // If absent, fall back to exponential backoff + jitter, capped at 32s.
                let retryAfterHeader = Double(resp.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                let exponentialBase = pow(2.0, Double(attempt))  // 1s, 2s, 4s
                let jitter = Double.random(in: 0...1.0)
                let delay = min(max(retryAfterHeader, exponentialBase + jitter), 32.0)
                logger.info("[Deepgram] HTTP \(resp.statusCode), retrying in \(String(format: "%.2f", delay))s (attempt \(attempt + 1)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            // Success or non-retryable failure — exit the retry loop
            break
        }

        guard let httpResponse else {
            throw DeepgramError.invalidResponse
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
                duration: rtt,
                headers: httpResponse.allHeaderFields,
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

        // v0.3.13 response classification:
        // - Happy path: non-empty transcript → return it.
        // - `noSpeechDetected`: Deepgram returned 200 OK with duration >= 0.5s and empty
        //   transcript AND empty words. This is the documented response for silent audio
        //   (see Deepgram discussions #765, #713, #756). Not a service error — route to
        //   observability-only handling in RecordingPopupView.
        // - `transcriptionFailed`: Deepgram returned 200 OK with duration < 0.5s or some
        //   other odd state. This is an actual service-side glitch worth escalating,
        //   and the request_id helps when filing Deepgram support tickets.
        if let transcript = firstAlt?.transcript, !transcript.isEmpty {
            logger.info("Deepgram transcription received (\(transcript.count) chars)")
            return transcript
        }

        let wordsEmpty = firstAlt?.words?.isEmpty ?? true
        if metaDuration >= 0.5 && wordsEmpty {
            throw DeepgramError.noSpeechDetected(durationSec: metaDuration)
        }
        throw DeepgramError.transcriptionFailed(requestId: decoded.metadata?.requestId)
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
        /// v0.3.13: Deepgram returned HTTP 200 with empty transcript for audio of
        /// duration >= 0.5s. This is Deepgram's documented response for silent audio —
        /// NOT a service error. Route to observability-only handling (no user dialog).
        case noSpeechDetected(durationSec: Double)
        /// v0.3.13: Deepgram returned HTTP 200 with empty transcript for audio of
        /// duration < 0.5s or some other odd state. Real service-side glitch.
        /// request_id is kept for Deepgram support tickets.
        case transcriptionFailed(requestId: String?)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Deepgram URL"
            case .invalidResponse: return "Invalid response from Deepgram"
            case .apiError(let code, let msg): return "Deepgram error (\(code)): \(msg)"
            case .noSpeechDetected(let duration):
                return "No speech detected in \(String(format: "%.1f", duration))s of audio"
            case .transcriptionFailed(let requestId):
                return "Deepgram returned empty result (request_id: \(requestId ?? "-"))"
            }
        }
    }
}
