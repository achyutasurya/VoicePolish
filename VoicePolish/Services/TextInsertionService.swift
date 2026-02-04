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
            throw TextInsertionError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        // keyUp flags intentionally left default (no .maskCommand)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        logger.info("Cmd+V posted via CGEvent (\(text.count) chars)")

        // 5. Wait for paste to complete. App behavior varies, so allow generous time.
        // The defer block above guarantees clipboard restoration regardless of how we exit.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
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
