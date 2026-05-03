import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class TextInsertionService {
    private let logger = LoggingService.shared

    /// Insert text into the previously focused application.
    /// Call this AFTER closing the popup and re-activating the target app.
    func insertText(_ text: String) async throws {
        // Log accessibility status but proceed regardless — the TCC database
        // can report false even when the permission is visually granted in System Settings
        // (stale code signature cache). We attempt the paste anyway.
        let trusted = AXIsProcessTrusted()
        logger.info("AXIsProcessTrusted = \(trusted), app path: \(Bundle.main.executablePath ?? "unknown")")

        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents (CRITICAL: must be restored later)
        let previousString = pasteboard.string(forType: .string)
        logger.info("Saved previous clipboard (\(previousString?.count ?? 0) chars)")

        // Ensure clipboard is restored even if paste fails or task is cancelled
        defer {
            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
                logger.debug("Previous clipboard restored")
            }
        }

        // 2. Set the text we want to paste
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Brief delay for clipboard to settle
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // 4. Simulate Cmd+V keypress
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            logger.error("Failed to create CGEvent")
            ErrorService.shared.addError(
                source: .textInsertion, severity: .error,
                message: "Failed to create paste keyboard event",
                code: "text_insertion.cgevent_create_failed"
            )
            throw TextInsertionError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        // keyUp flags intentionally left default (no .maskCommand)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        logger.info("Cmd+V posted via CGEvent (\(text.count) chars)")

        // 5. Wait for paste to complete. App behavior varies, so allow generous time.
        // The defer block above guarantees clipboard restoration regardless of how we exit.
        //
        // v0.3.17: bumped 200ms → 500ms. Industry consensus (Igor Kulman, Multi.app)
        // is that 200ms is too short for Electron-based apps (Slack, Discord, the
        // VS Code Electron host) which need closer to 400-500ms to consume the
        // pasteboard. The user doesn't perceive the extra 300ms; the gain is that
        // clipboard restore no longer races the target app's paste handler.
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
    }

    /// Insert text by typing characters as keyboard events.
    /// This path bypasses clipboard dependencies and is intended for remote sessions (for example Citrix).
    func typeTextForCitrix(_ text: String) async throws {
        let normalizedText = Self.normalizeCitrixTypingText(text)
        guard !normalizedText.isEmpty else {
            logger.info("Citrix typing: nothing to type (empty text)")
            return
        }

        let preset = AppSettings.shared.citrixTypingSpeedPreset
        let interKeyDelayMs = max(0, AppSettings.shared.citrixTypingInterKeyDelayMs)
        let newlineDelayMs = max(0, AppSettings.shared.citrixTypingNewlineDelayMs)
        let chunkSize = max(1, AppSettings.shared.citrixTypingChunkSize)
        let chunkPauseMs = max(0, AppSettings.shared.citrixTypingChunkPauseMs)
        let wordPauseMinMs = max(0, AppSettings.shared.citrixTypingWordPauseMinMs)
        let wordPauseMaxMs = max(wordPauseMinMs, AppSettings.shared.citrixTypingWordPauseMaxMs)
        let charJitterMs = max(0, AppSettings.shared.citrixTypingCharJitterMs)
        let chunks = Self.makeCitrixTypingChunks(from: normalizedText, chunkSize: chunkSize)

        logger.info(
            "Citrix typing: start (preset=\(preset.rawValue), \(normalizedText.count) chars, delay=\(interKeyDelayMs)ms, newlineDelay=\(newlineDelayMs)ms, chunkSize=\(chunkSize), chunkPause=\(chunkPauseMs)ms, wordPause=\(wordPauseMinMs)-\(wordPauseMaxMs)ms, jitter=±\(charJitterMs)ms)"
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        var typedCharacters = 0

        for (chunkIndex, chunk) in chunks.enumerated() {
            for character in chunk {
                try postCharacterForCitrix(character)
                typedCharacters += 1

                let delayMs = Self.nextDelayMsForCitrixCharacter(
                    character,
                    interKeyDelayMs: interKeyDelayMs,
                    newlineDelayMs: newlineDelayMs,
                    wordPauseMinMs: wordPauseMinMs,
                    wordPauseMaxMs: wordPauseMaxMs,
                    charJitterMs: charJitterMs
                )
                if delayMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }

            let isLastChunk = chunkIndex == chunks.count - 1
            if !isLastChunk && chunkPauseMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(chunkPauseMs) * 1_000_000)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        logger.info("Citrix typing: complete (\(typedCharacters) chars in \(String(format: "%.2f", elapsed))s)")
    }

    private func postCharacterForCitrix(_ character: Character) throws {
        switch character {
        case "\n":
            try postVirtualKey(CGKeyCode(kVK_Return))
            return
        case "\t":
            try postVirtualKey(CGKeyCode(kVK_Tab))
            return
        default:
            break
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(0), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(0), keyDown: false)
        else {
            logger.error("Citrix typing: failed to create unicode CGEvent")
            throw TextInsertionError.eventCreationFailed
        }

        let utf16Units = Array(String(character).utf16)
        utf16Units.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: baseAddress)
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func postVirtualKey(_ keyCode: CGKeyCode) throws {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            logger.error("Citrix typing: failed to create virtual key CGEvent")
            throw TextInsertionError.eventCreationFailed
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    nonisolated static func normalizeCitrixTypingText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    nonisolated static func makeCitrixTypingChunks(from text: String, chunkSize: Int) -> [Substring] {
        let safeChunkSize = max(1, chunkSize)
        var chunks: [Substring] = []
        var startIndex = text.startIndex

        while startIndex < text.endIndex {
            let endIndex = text.index(startIndex, offsetBy: safeChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(text[startIndex..<endIndex])
            startIndex = endIndex
        }

        return chunks
    }

    nonisolated static func nextDelayMsForCitrixCharacter(
        _ character: Character,
        interKeyDelayMs: Int,
        newlineDelayMs: Int,
        wordPauseMinMs: Int,
        wordPauseMaxMs: Int,
        charJitterMs: Int
    ) -> Int {
        if character == " " {
            let minDelay = max(0, wordPauseMinMs)
            let maxDelay = max(minDelay, wordPauseMaxMs)
            return Int.random(in: minDelay...maxDelay)
        }

        let baseDelay: Int
        switch character {
        case "\n":
            baseDelay = max(0, newlineDelayMs)
        default:
            baseDelay = max(0, interKeyDelayMs)
        }

        guard charJitterMs > 0 else {
            return baseDelay
        }

        let jitter = Int.random(in: -charJitterMs...charJitterMs)
        return max(0, baseDelay + jitter)
    }

    enum TextInsertionError: LocalizedError {
        case eventCreationFailed
        case accessibilityNotGranted

        var errorDescription: String? {
            switch self {
            case .eventCreationFailed: return "Failed to create keyboard event"
            case .accessibilityNotGranted: return "Accessibility permission not granted"
            }
        }
    }
}
