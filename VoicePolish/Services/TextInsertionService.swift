import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KeyboardShortcuts

@MainActor
@Observable
final class TextInsertionService {
    private let logger = LoggingService.shared
    private let engine: TypingEngineProtocol

    /// True while a keystroke typing run is in flight. Read by AppState so
    /// Cmd+[ can abort a run whose popup has already closed, and by the menubar
    /// icon.
    private(set) var isTyping = false

    init(engine: TypingEngineProtocol = KeystrokeTypingEngine()) {
        self.engine = engine
    }

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

    /// Insert text by typing it as real keyboard events.
    ///
    /// Used by Stop & Type for remote-desktop sessions where the clipboard is
    /// unavailable. Posts the real virtual key code and real modifier key events
    /// for the current layout, plus the Unicode payload -- a strict superset, so
    /// scan-code clients (Microsoft Windows App, VNC, VMware) and character
    /// clients (Citrix, Cocoa text views) are both satisfied.
    @discardableResult
    func typeTextAsKeystrokes(_ text: String) async throws -> KeystrokeTypingReport {
        // Single-flight. `focusTargetApp` closes the popup BEFORE typing starts,
        // so the per-view `popupState` guard in RecordingPopupView cannot see a
        // run that is still in flight. Two KeyCodeEmitters would each track their
        // own `heldFlags` and silently corrupt each other's capitalisation.
        //
        // This service is one instance per process (AppState owns it), so it is
        // the only thing that outlives the popup.
        guard !isTyping else {
            logger.error("Stop & Type: a typing run is already in flight — ignoring (text is recoverable from History)")
            return .busy
        }
        isTyping = true
        KeystrokeTypingEngine.isRunInFlight = true
        defer {
            isTyping = false
            KeystrokeTypingEngine.isRunInFlight = false
        }

        // Events posted at .cghidEventTap traverse the full Window Server
        // pipeline, INCLUDING Carbon hot-key matching (KeyboardShortcuts uses
        // RegisterEventHotKey). On a U.S. layout Option+. is "≥" — which is the
        // Stop & Type binding itself, so typing that character would re-trigger
        // the feature mid-run.
        //
        // .cancelRecording stays enabled on purpose: it is the abort path, and
        // its Cmd+[ default is unreachable by us since we only ever post Shift
        // and Option, never Command or Control.
        // .stopAndType is the one that matters: on a U.S. layout its default
        // Option+. IS the character U+2265, so typing a "greater than or equal"
        // would re-trigger it. Carbon hot keys CONSUME the event, so the
        // character would silently vanish from the output with no diagnostic.
        // .toggleRecording is belt-and-braces (Cmd+] is unreachable by us).
        // The user-chosen alternates (v0.3.33) can be anything, so they follow the
        // same rule: see HotkeyAction.namesToSuspendWhileTyping. Snapshot the list so
        // the defer re-enables exactly what was disabled.
        let suspendedHotkeys = HotkeyAction.namesToSuspendWhileTyping
        KeyboardShortcuts.disable(suspendedHotkeys)
        defer { KeyboardShortcuts.enable(suspendedHotkeys) }

        let normalizedText = Self.normalizeCitrixTypingText(text)
        guard !normalizedText.isEmpty else {
            logger.info("Stop & Type: nothing to type (empty text)")
            return KeystrokeTypingReport()
        }

        let settings = AppSettings.shared
        let config = TypingConfig(
            interKeyDelayMs: max(0, settings.citrixTypingInterKeyDelayMs),
            newlineDelayMs: max(0, settings.citrixTypingNewlineDelayMs),
            chunkSize: max(1, settings.citrixTypingChunkSize),
            chunkPauseMs: max(0, settings.citrixTypingChunkPauseMs),
            wordPauseMinMs: max(0, settings.citrixTypingWordPauseMinMs),
            wordPauseMaxMs: max(max(0, settings.citrixTypingWordPauseMinMs), settings.citrixTypingWordPauseMaxMs),
            charJitterMs: max(0, settings.citrixTypingCharJitterMs),
            preferLegacyUnicode: settings.typingMethod == .legacyUnicode,
            asciiFoldEnabled: settings.typingAsciiFoldEnabled
        )
        let preset = settings.citrixTypingSpeedPreset

        // Build the layout map ONCE, here, and pass it to the engine. This is
        // the single decision point: the fold needs the map, and letting the
        // engine build a second one could diverge -- if this build failed while
        // the engine's succeeded, the run would type with real keystrokes and no
        // fold at all.
        var textToType = normalizedText
        var layoutSnapshot: KeyboardLayoutMap.Snapshot?
        var layoutUnavailableReason: String?
        if !config.preferLegacyUnicode {
            do {
                layoutSnapshot = try KeyboardLayoutMap.build()
            } catch {
                layoutUnavailableReason =
                    "Keyboard layout unavailable (\(error.localizedDescription)); used Unicode typing."
                logger.error("Stop & Type: \(layoutUnavailableReason!)")
            }
        }
        if config.asciiFoldEnabled, let snapshot = layoutSnapshot, !snapshot.inputMethodActive {
            textToType = TypingTextFolder.fold(normalizedText) { snapshot.requiresOptionOrIsUnreachable($0) }
            if textToType != normalizedText {
                logger.info("Stop & Type: folded \(normalizedText.count) chars -> \(textToType.count) chars for layout reachability")
            }
        }

        logger.info(
            "Stop & Type: start (preset=\(preset.rawValue), \(textToType.count) chars, delay=\(config.interKeyDelayMs)ms, newlineDelay=\(config.newlineDelayMs)ms, chunkSize=\(config.chunkSize), chunkPause=\(config.chunkPauseMs)ms, wordPause=\(config.wordPauseMinMs)-\(config.wordPauseMaxMs)ms, jitter=±\(config.charJitterMs)ms, method=\(config.preferLegacyUnicode ? "legacyUnicode" : "auto"))"
        )

        let report = try await engine.type(
            text: textToType,
            config: config,
            prebuiltLayout: layoutSnapshot,
            layoutUnavailableReason: layoutUnavailableReason,
            delayMs: { character in
                Self.nextDelayMsForCitrixCharacter(
                    character,
                    interKeyDelayMs: config.interKeyDelayMs,
                    newlineDelayMs: config.newlineDelayMs,
                    wordPauseMinMs: config.wordPauseMinMs,
                    wordPauseMaxMs: config.wordPauseMaxMs,
                    charJitterMs: config.charJitterMs
                )
            },
            onProgress: { _ in }
        )

        logger.info(
            "Stop & Type: complete (\(report.charactersTyped) chars in \(String(format: "%.2f", report.elapsedSeconds))s, method=\(report.methodUsed.rawValue), delivered=\(report.deliveredKeyDownCount)/\(report.expectedKeyDownCount), layout=\(report.layoutSummary), inputSource=\(report.inputSourceAtTypingStart))"
        )
        return report
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
