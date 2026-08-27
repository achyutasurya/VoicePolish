import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import IOKit
import IOKit.hidsystem

/// Which emitter a run ended up using.
enum ResolvedTypingMethod: String, Sendable {
    case realKeystrokes
    case legacyUnicode
}

/// Everything a run needs from AppSettings, snapshotted on the MainActor before
/// the loop starts. A value type so the loop never reaches back into
/// `@MainActor AppSettings`, and so timing tests can be written without
/// UserDefaults.
struct TypingConfig: Sendable {
    var interKeyDelayMs: Int
    var newlineDelayMs: Int
    var chunkSize: Int
    var chunkPauseMs: Int
    var wordPauseMinMs: Int
    var wordPauseMaxMs: Int
    var charJitterMs: Int
    var preferLegacyUnicode: Bool
    var asciiFoldEnabled: Bool
}

/// What actually happened, so the caller can log it and raise exactly one
/// ErrorService entry.
struct KeystrokeTypingReport: Sendable {
    var charactersTyped = 0
    var foldedCharacters: [Character] = []
    var degradedCharacters: [Character] = []
    var methodUsed: ResolvedTypingMethod = .realKeystrokes
    var methodOverrideReason: String?
    var expectedKeyDownCount = 0
    var deliveredKeyDownCount = 0
    var secureInputActive = false
    /// Whether the process held Accessibility trust at run time. This, not the
    /// key-down counter, is the reliable "nothing was delivered" signal.
    var accessibilityTrusted = true
    /// A character key whose key-up could not be posted.
    var stuckKeyCode: CGKeyCode?
    var modifiersForceCleared = false
    var capsLockCleared = false
    var stuckModifiers: CGEventFlags = []
    var layoutSummary = ""
    var inputSourceAtTypingStart = ""
    var wasBusy = false
    var elapsedSeconds: Double = 0

    static var busy: KeystrokeTypingReport {
        var report = KeystrokeTypingReport()
        report.wasBusy = true
        return report
    }

    /// Nothing could have been delivered: CGEvent posts are silently dropped
    /// without Accessibility trust.
    ///
    /// Deliberately NOT derived from the key-down counter. Measured on macOS 26:
    /// posting 10 key-downs moved CGEventSourceCounterForEventType by 0 on both
    /// .hidSystemState and .combinedSessionState while a tap confirmed all 10
    /// were emitted -- so a counter-based check would fire on every successful
    /// run. The counter is kept as a log line only.
    var deliveredNothing: Bool { charactersTyped > 0 && !accessibilityTrusted }
}

protocol TypingEngineProtocol: Sendable {
    @MainActor
    func type(
        text: String,
        config: TypingConfig,
        prebuiltLayout: KeyboardLayoutMap.Snapshot?,
        layoutUnavailableReason: String?,
        delayMs: @escaping (Character) -> Int,
        onProgress: @escaping (Int) -> Void
    ) async throws -> KeystrokeTypingReport
}

struct KeystrokeTypingEngine: TypingEngineProtocol {

    @MainActor
    func type(
        text: String,
        config: TypingConfig,
        prebuiltLayout: KeyboardLayoutMap.Snapshot?,
        layoutUnavailableReason: String?,
        delayMs: @escaping (Character) -> Int,
        onProgress: @escaping (Int) -> Void
    ) async throws -> KeystrokeTypingReport {
        var report = KeystrokeTypingReport()
        guard !text.isEmpty else { return report }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw KeystrokeEmitterError.eventSourceUnavailable
        }
        // Never suppress the user's own input as a side effect of ours.
        source.localEventsSuppressionInterval = 0

        // --- Resolve the emitter -------------------------------------------
        // The layout map MUST be built here, after focusTargetApp has already
        // activated the target: with "automatically switch to a document's input
        // source" enabled, activating an app can change the current source.
        // The CALLER is the single decision point for the layout snapshot: it
        // needs the map to drive the layout-aware fold, so building a second one
        // here could diverge -- and if the caller's build failed while ours
        // succeeded, the run would use real keystrokes with NO fold applied,
        // which is the worst combination available.
        var layout: KeyboardLayoutMap.Snapshot?
        if config.preferLegacyUnicode {
            report.methodOverrideReason = "Legacy Unicode typing selected in Settings."
        } else if let prebuiltLayout {
            report.layoutSummary = prebuiltLayout.summary
            if prebuiltLayout.inputMethodActive {
                report.methodOverrideReason =
                    "An input method is active, so Unicode typing was used instead of key codes."
            } else {
                layout = prebuiltLayout
            }
        } else {
            report.methodOverrideReason = layoutUnavailableReason
                ?? "Keyboard layout unavailable; used Unicode typing."
        }

        let emitter: KeystrokeEmitting
        let keyCodeEmitter: KeyCodeEmitter?
        if let layout {
            let concrete = KeyCodeEmitter(source: source, layout: layout)
            emitter = concrete
            keyCodeEmitter = concrete
            report.methodUsed = .realKeystrokes
        } else {
            emitter = LegacyUnicodeEmitter(source: source)
            keyCodeEmitter = nil
            report.methodUsed = .legacyUnicode
        }

        // Registered BEFORE anything can post, so cancellation or a thrown error
        // can never strand Shift down on the remote machine.
        defer { emitter.unwind() }

        // --- Environment ----------------------------------------------------
        if report.methodUsed == .realKeystrokes {
            // One read, not a polling loop: the hotkey fires long before typing
            // starts (Deepgram + the LLM + a 500ms focus hand-off in between), so
            // the trigger modifier is released by now. This covers a genuinely
            // stuck key, and force-clearing beats proceeding -- a latched Option
            // is read from global HID state and makes every character arrive
            // Option-modified, which per-event .flags cannot rescue.
            let held = CGEventSource.flagsState(.hidSystemState)
                .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
            if !held.isEmpty {
                Self.forceReleaseModifiers(held, source: source)
                report.modifiersForceCleared = true
            }

            // Caps Lock is visible to clients reading global HID state regardless
            // of per-event flags, so it would invert the Shift logic. Clear only,
            // never restore: restoring would push a caps-lock change into the
            // remote session at an arbitrary moment and stomp a mid-run toggle.
            if CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) {
                Self.setCapsLock(false)
                report.capsLockCleared = true
            }
        }

        // Advisory only. Secure Input is system-wide (Terminal's Secure Keyboard
        // Entry, any focused password field), far too noisy to be an error alone.
        report.secureInputActive = IsSecureEventInputEnabled()
        report.inputSourceAtTypingStart = KeyboardLayoutMap.currentInputSourceID() ?? "unknown"

        // --- Type -----------------------------------------------------------
        let timing = KeystrokeTiming.forInterKeyDelay(config.interKeyDelayMs)
        let chunks = TextInsertionService.makeCitrixTypingChunks(from: text, chunkSize: config.chunkSize)
        let before = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        let startedAt = CFAbsoluteTimeGetCurrent()

        for (chunkIndex, chunk) in chunks.enumerated() {
            for character in chunk {
                try Task.checkCancellation()

                let elapsedBefore = CFAbsoluteTimeGetCurrent()
                let result = try await emitter.emit(character: character, timing: timing)
                let consumedMs = Int((CFAbsoluteTimeGetCurrent() - elapsedBefore) * 1000)

                switch result {
                case .faithful:
                    report.charactersTyped += 1
                case .folded(let original):
                    report.charactersTyped += 1
                    report.foldedCharacters.append(original)
                case .degraded(let original):
                    report.charactersTyped += 1
                    report.degradedCharacters.append(original)
                case .deleted:
                    // Nothing was posted; counting it would overstate the run.
                    break
                }
                onProgress(report.charactersTyped)

                let delay = delayMs(character)
                // Word and newline pauses are documented as GAPS ("random
                // 150-250ms pause between words"), so they are never reduced by
                // what the keystroke itself consumed. Ordinary inter-key delays
                // absorb the hold so overall cadence matches the previous build,
                // with a floor so key-up -> next key-down is never 0ms.
                let isPause = character == " " || character == "\n" || character == "\r\n" || character == "\r"
                let sleepMs = isPause ? delay : max(Self.minimumGapMs, delay - consumedMs)
                try await emitter.sleep(milliseconds: sleepMs)
            }

            let isLastChunk = chunkIndex == chunks.count - 1
            if !isLastChunk {
                // Never hold Shift across a multi-hundred-millisecond pause with
                // no key down.
                keyCodeEmitter?.releaseModifiersBetweenChunks()
                if config.chunkPauseMs > 0 {
                    try await emitter.sleep(milliseconds: config.chunkPauseMs)
                }
            }
        }

        // Unwind BEFORE reading the emitter's post-unwind state. The `defer`
        // above runs after the return value is built, so reading stuckModifiers
        // without this always saw the initializer's empty set -- which made the
        // "a modifier may still be held" warning unreachable. unwind() is
        // idempotent, so the defer remains a valid throw/cancel backstop.
        emitter.unwind()

        let after = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        report.elapsedSeconds = CFAbsoluteTimeGetCurrent() - startedAt
        report.expectedKeyDownCount = emitter.postedKeyDownCount
        report.deliveredKeyDownCount = Int(after) - Int(before)
        report.stuckModifiers = emitter.stuckModifiers
        report.stuckKeyCode = emitter.stuckKeyCode
        report.accessibilityTrusted = AXIsProcessTrusted()
        return report
    }

    /// Floor on the key-up -> next key-down gap. Without it the fastest preset's
    /// jittered delay drops below the key hold about a quarter of the time and
    /// produces a continuously-depressed key -- the exact shape the hold exists
    /// to avoid.
    static let minimumGapMs = 8

    /// Posts real key-ups for modifiers that are physically latched before a run.
    ///
    /// Covers BOTH the left and right key code for each modifier: a latched right
    /// Option is not cleared by releasing the left one.
    static func forceReleaseModifiers(_ flags: CGEventFlags, source: CGEventSource?) {
        let pairs: [(CGKeyCode, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), .maskCommand), (CGKeyCode(kVK_RightCommand), .maskCommand),
            (CGKeyCode(kVK_Control), .maskControl), (CGKeyCode(kVK_RightControl), .maskControl),
            (CGKeyCode(kVK_Option), .maskAlternate), (CGKeyCode(kVK_RightOption), .maskAlternate),
            (CGKeyCode(kVK_Shift), .maskShift), (CGKeyCode(kVK_RightShift), .maskShift),
        ]
        var remaining = flags
        for (keyCode, mask) in pairs where flags.contains(mask) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            else { continue }
            // Stamp the state AFTER this release. Leaving flags unset means the
            // event inherits the still-latched hardware flags, i.e. it advertises
            // the very modifier it is releasing.
            remaining.remove(mask)
            event.flags = remaining
            event.post(tap: .cghidEventTap)
        }
    }

    /// True while a keystroke run is in flight. Readable from the app delegate
    /// during termination, when the MainActor-isolated service is no longer a
    /// safe thing to reach for.
    nonisolated(unsafe) static var isRunInFlight = false

    /// Last-resort drain used on app termination.
    ///
    /// The emitter is a local inside `type(...)`, so nothing outside can call
    /// `unwind()` once the process is tearing down -- and a modifier latched on a
    /// remote machine has no recovery short of physically pressing it.
    ///
    /// Only runs when a run is actually in flight, and only for Shift and Option:
    /// those are the only modifiers typing ever presses. Draining Command and
    /// Control unconditionally would desync a modifier the user is holding while
    /// quitting.
    static func drainModifiersOnTerminate() {
        guard isRunInFlight else { return }
        let keyCodes: [Int] = [kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption]
        for keyCode in keyCodes {
            guard let event = CGEvent(keyboardEventSource: nil,
                                      virtualKey: CGKeyCode(keyCode), keyDown: false)
            else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    /// Clears (or sets) the hardware Caps Lock via the HID system.
    private static func setCapsLock(_ on: Bool) {
        let matching = IOServiceMatching(kIOHIDSystemClass)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_,
                            UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }

        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }
}
