import Carbon
import CoreGraphics
import Foundation

/// Errors raised by the emitters.
///
/// Deliberately its own type rather than `TextInsertionService.TextInsertionError`:
/// that enum is nested inside a `@MainActor` class that imports AppKit,
/// LoggingService and ErrorService, and throwing it here would drag the entire
/// app into `scripts/dev/main.swift`'s compile.
enum KeystrokeEmitterError: LocalizedError {
    case eventSourceUnavailable
    case keyboardEventUnavailable

    var errorDescription: String? {
        switch self {
        case .eventSourceUnavailable: return "Unable to create keyboard event source."
        case .keyboardEventUnavailable: return "Unable to create keyboard event."
        }
    }
}

/// Per-keystroke timing, derived from the user's speed preset.
struct KeystrokeTiming: Sendable {
    var holdMilliseconds: Int
    var modifierLeadMilliseconds: Int
    var modifierTrailMilliseconds: Int

    static let immediate = KeystrokeTiming(holdMilliseconds: 0,
                                           modifierLeadMilliseconds: 0,
                                           modifierTrailMilliseconds: 0)

    /// hold is a FRACTION of the interval budget rather than a fixed value: at
    /// the fastest preset the whole budget is 20ms, so a fixed 25-40ms hold plus
    /// modifier lead/trail would exceed it and make the preset unreachable.
    ///
    /// lead/trail are constants, not formulas. The reference computes them as
    /// clamp(d/12, 8, 24) and clamp(d/16, 6, 20), which only exceed their floors
    /// at d >= 96 -- and the largest shipping preset is d = 90.
    static func forInterKeyDelay(_ interKeyDelayMs: Int) -> KeystrokeTiming {
        let hold = min(110, max(10, Int(Double(max(0, interKeyDelayMs)) * 0.45)))
        return KeystrokeTiming(holdMilliseconds: hold,
                               modifierLeadMilliseconds: 8,
                               modifierTrailMilliseconds: 6)
    }
}

/// The outcome of emitting one character.
enum KeystrokeEmitResult: Equatable {
    /// Typed exactly as requested.
    case faithful
    /// Typed, but not as the original character (diacritic folded).
    case folded(Character)
    /// Could not be represented on this layout; a space was posted instead.
    case degraded(Character)
    /// Intentionally removed (soft hyphen, zero-width space). Nothing was posted,
    /// so this must NOT be counted as a typed character.
    case deleted(Character)
}

/// Posts keystrokes for one character at a time.
///
/// A class, not a struct, because it tracks which modifiers and which character
/// key are currently held down, and the engine must be able to unwind that from
/// a `defer` on every exit path -- otherwise cancelling mid-run can strand Shift
/// in the down state on a remote machine.
protocol KeystrokeEmitting: AnyObject {
    /// Number of key-DOWN events posted (modifier events excluded -- CoreGraphics
    /// turns those into flagsChanged, which the key-down counter does not count).
    var postedKeyDownCount: Int { get }
    /// Modifiers still held after `unwind()` gave up. Empty is the happy path.
    var stuckModifiers: CGEventFlags { get }
    /// A character key whose key-up could not be posted. nil is the happy path.
    var stuckKeyCode: CGKeyCode? { get }

    func emit(character: Character, timing: KeystrokeTiming) async throws -> KeystrokeEmitResult
    /// Release every key and modifier this emitter is holding. Idempotent.
    func unwind()
}

extension KeystrokeEmitting {
    /// Sleep in a way that stays responsive to cancellation. The engine checks
    /// once per character, but a single character spans several sub-sleeps, so
    /// Cancel would otherwise lag by up to a full keystroke.
    func sleep(milliseconds: Int) async throws {
        guard milliseconds > 0 else { return }
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    /// A sleep that CANNOT throw, used only between a key-down and its key-up.
    ///
    /// Cancelling in that window must never skip the key-up: the key would stay
    /// physically down, and on a remote session autorepeat would then spew
    /// characters until something else released it. Cancellation still shortens
    /// the hold (`Task.sleep` returns immediately once cancelled), it just can no
    /// longer strand the key. This is the single most important safety property
    /// in the whole design.
    func uninterruptibleSleep(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

// MARK: - Real key codes

/// Posts real virtual key codes with real modifier key events, and attaches the
/// Unicode payload as well.
///
/// Attaching both makes this a strict superset of the Unicode strategy:
/// scan-code readers (Windows App, VNC, VMware) consume the key code, character
/// readers (Citrix, Cocoa text views) consume the payload. Splashtop Streamer
/// does exactly this -- its binary imports `_UCKeyTranslate` and
/// `_CGEventKeyboardSetUnicodeString` together.
final class KeyCodeEmitter: KeystrokeEmitting {
    private let source: CGEventSource
    private let layout: KeyboardLayoutMap.Snapshot
    private let keyboardType: Int64
    private let postHandler: (CGEvent) -> Void

    private var heldFlags: CGEventFlags = []
    private var pendingKeyDown: CGKeyCode?
    /// Every modifier this emitter has ever successfully pressed.
    ///
    /// Scopes the HID ground-truth check in `unwind()`. `CGEventSource.keyState`
    /// reports the combined state of all HARDWARE sources -- the user's fingers,
    /// not just our synthetic presses -- so draining everything it reports as
    /// down would release a modifier the user is physically holding. Typing only
    /// ever presses Shift and Option, so Command and Control can never enter this
    /// set, and the Cmd+[ abort gesture is safe.
    private var everPressed: CGEventFlags = []
    private var didUnwind = false

    private(set) var postedKeyDownCount = 0
    private(set) var stuckModifiers: CGEventFlags = []
    private(set) var stuckKeyCode: CGKeyCode?

    init(source: CGEventSource,
         layout: KeyboardLayoutMap.Snapshot,
         postHandler: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.source = source
        self.layout = layout
        // Read ONCE from the snapshot, not LMGetKbdType() per event: a keyboard
        // hot-swap mid-run would otherwise desync the stamp from the map the
        // strokes were resolved against.
        self.keyboardType = Int64(layout.keyboardType)
        self.postHandler = postHandler
    }

    func emit(character: Character, timing: KeystrokeTiming) async throws -> KeystrokeEmitResult {
        // "\r\n" is a SINGLE Swift Character (UAX #29 keeps CR LF together) and
        // is NOT equal to "\n". The caller normalises it away first; this is
        // defence in depth so a CRLF can never fall through to the unmappable
        // path and become a space.
        if character == "\n" || character == "\r\n" || character == "\r" {
            // Release any held modifier first. Posting Return while Shift is
            // still down delivers Shift+Enter, which is a DIFFERENT keystroke in
            // most applications (send vs. newline, or move-up in a grid).
            try await applyModifiers([], timing: timing)
            try await post(keyCode: CGKeyCode(kVK_Return), flags: heldFlags, unicode: nil, timing: timing)
            return .faithful
        }
        if character == "\t" {
            try await applyModifiers([], timing: timing)
            try await post(keyCode: CGKeyCode(kVK_Tab), flags: heldFlags, unicode: nil, timing: timing)
            return .faithful
        }

        if let stroke = layout.stroke(for: character) {
            try await applyModifiers(stroke.flags, timing: timing)
            // Stamp what is ACTUALLY held, not what was wanted. If a modifier
            // press failed to post, `heldFlags` reflects that and `stroke.flags`
            // does not -- and a flagsChanged-tracking scan-code client would then
            // be told about an Alt that was never pressed.
            try await post(keyCode: stroke.keyCode, flags: heldFlags,
                           unicode: String(character), timing: timing)
            return .faithful
        }

        // Not directly reachable on this layout. Try a fold before giving up --
        // "cafe" beats "caf ".
        //
        // NOTE the scope: this only rescues characters with NO stroke at all. A
        // character that IS reachable but needs Option (an em dash, a curly
        // quote) is typed as a real Option keystroke and never reaches here --
        // that is what the string-level fold in TypingTextFolder is for, and
        // turning that setting off deliberately opts into literal typing.
        if let folded = TypingTextFolder.foldCharacter(character) {
            if folded.isEmpty {
                // A deliberate deletion (soft hyphen, zero-width space). Post
                // nothing, and do not let the caller count it as typed.
                return .deleted(character)
            }
            if folded.allSatisfy({ layout.stroke(for: $0) != nil }) {
                for piece in folded {
                    guard let stroke = layout.stroke(for: piece) else { continue }
                    try await applyModifiers(stroke.flags, timing: timing)
                    try await post(keyCode: stroke.keyCode, flags: heldFlags,
                                   unicode: String(piece), timing: timing)
                }
                return .folded(character)
            }
        }

        // Genuinely unrepresentable (emoji, CJK). Carry it on kVK_Space so a
        // scan-code reader sees a space rather than a stray character -- the same
        // fallback Chromium uses in remoting/host/input_injector_mac.cc.
        try await applyModifiers([], timing: timing)
        try await post(keyCode: CGKeyCode(kVK_Space), flags: heldFlags,
                       unicode: String(character), timing: timing)
        return .degraded(character)
    }

    /// Idempotent: the engine calls this explicitly before building its report,
    /// and again from a `defer` that covers throw and cancellation.
    func unwind() {
        guard !didUnwind else { return }
        didUnwind = true

        // The character key first: if key-UP creation failed mid-post, the key is
        // still physically down and releasing only modifiers would leave it there
        // to autorepeat on the remote machine.
        if let pending = pendingKeyDown {
            // Only clear on a confirmed post. Clearing regardless meant the one
            // scenario where a key is genuinely stuck was the one that gave up
            // silently.
            if postRaw(keyCode: pending, keyDown: false, flags: heldFlags, unicode: nil) {
                pendingKeyDown = nil
            } else if postRaw(keyCode: pending, keyDown: false, flags: heldFlags, unicode: nil) {
                pendingKeyDown = nil
            }
            stuckKeyCode = pendingKeyDown
        }

        if !heldFlags.isEmpty {
            let released = postModifiers(heldFlags, down: false, from: heldFlags)
            heldFlags.subtract(released)
            if !heldFlags.isEmpty {
                let retry = postModifiers(heldFlags, down: false, from: heldFlags)
                heldFlags.subtract(retry)
            }
        }

        // Ground truth, but scoped to modifiers WE pressed.
        //
        // CGEventSource.keyState reports the combined state of all hardware
        // sources, so an unscoped drain would release a key the user is
        // physically holding -- which happens on the designed abort path, where
        // Cmd+[ means their finger is on Command at exactly this moment.
        var stillDown: CGEventFlags = []
        for (keyCode, mask) in Self.modifierKeys
        where everPressed.contains(mask) && CGEventSource.keyState(.hidSystemState, key: keyCode) {
            stillDown.insert(mask)
        }
        if !stillDown.isEmpty {
            _ = postModifiers(stillDown, down: false, from: stillDown)
            var remaining: CGEventFlags = []
            for (keyCode, mask) in Self.modifierKeys
            where everPressed.contains(mask) && CGEventSource.keyState(.hidSystemState, key: keyCode) {
                remaining.insert(mask)
            }
            stuckModifiers = remaining
        } else {
            stuckModifiers = []
        }
        heldFlags = []
    }

    /// Release held modifiers without ending the run -- used at chunk boundaries
    /// so Shift is never held across a multi-hundred-millisecond pause with no
    /// key down.
    func releaseModifiersBetweenChunks() {
        guard !heldFlags.isEmpty else { return }
        let released = postModifiers(heldFlags, down: false, from: heldFlags)
        heldFlags.subtract(released)
    }

    // MARK: - Modifiers

    private static let modifierKeys: [(CGKeyCode, CGEventFlags)] = [
        (CGKeyCode(kVK_Shift), .maskShift),
        (CGKeyCode(kVK_Option), .maskAlternate),
        (CGKeyCode(kVK_Control), .maskControl),
        (CGKeyCode(kVK_Command), .maskCommand),
    ]

    /// Press and release only the *difference*, so Shift stays down across a run
    /// of capitals the way a real typist holds it. Toggling per character would
    /// mean ~7 Shift transitions a second on an acronym, which is itself a tell
    /// and extra traffic on the remote wire.
    private func applyModifiers(_ wanted: CGEventFlags, timing: KeystrokeTiming) async throws {
        guard heldFlags != wanted else { return }

        let release = heldFlags.subtracting(wanted)
        if !release.isEmpty {
            let released = postModifiers(release, down: false, from: heldFlags)
            // Only subtract what ACTUALLY posted. Assuming success here is the
            // bug that leaves the emitter believing Shift is up while it is
            // physically down.
            heldFlags.subtract(released)
            if !released.isEmpty {
                try await sleep(milliseconds: timing.modifierTrailMilliseconds)
            }
        }

        let press = wanted.subtracting(heldFlags)
        if !press.isEmpty {
            let pressed = postModifiers(press, down: true, from: heldFlags)
            // Same rule in the other direction: unioning the whole `press` set
            // when an event failed to be created would make the emitter stamp
            // every later `.flags` wrong and post a spurious Shift-up at unwind.
            heldFlags.formUnion(pressed)
            everPressed.formUnion(pressed)
            if !pressed.isEmpty {
                // Let the modifier state settle before the key lands: an RDP
                // client has to marshal the change into a wire PDU first.
                try await sleep(milliseconds: timing.modifierLeadMilliseconds)
            }
        }
    }

    /// Posts real modifier key events and returns the subset that actually made
    /// it out. CoreGraphics converts a keyboard event carrying a modifier key
    /// code into a `flagsChanged` event by itself (CGEvent.h:65-67), so there is
    /// no `.type` to set here.
    @discardableResult
    private func postModifiers(_ changing: CGEventFlags, down: Bool, from current: CGEventFlags) -> CGEventFlags {
        var pairs = Self.modifierKeys.filter { changing.contains($0.1) }
        if !down { pairs.reverse() }

        var accumulated = current
        var actuallyChanged: CGEventFlags = []

        for (keyCode, mask) in pairs {
            var next = accumulated
            if down { next.insert(mask) } else { next.remove(mask) }

            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            else { continue }
            event.flags = next
            stamp(event)
            postHandler(event)

            accumulated = next
            actuallyChanged.insert(mask)
        }
        return actuallyChanged
    }

    // MARK: - Character keys

    /// The key-up event is created *after* the hold, not up front.
    ///
    /// `CGEvent(keyboardEventSource:...)` stamps `timestamp` at creation time, so
    /// building both events together and sleeping between the posts would record
    /// a ~0 ms hold in the event stream even though wall-clock showed 40 ms --
    /// defeating the whole point of holding the key.
    private func post(keyCode: CGKeyCode,
                      flags: CGEventFlags,
                      unicode: String?,
                      timing: KeystrokeTiming) async throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            throw KeystrokeEmitterError.keyboardEventUnavailable
        }
        down.flags = flags
        stamp(down)
        attach(unicode, to: down)
        postHandler(down)
        pendingKeyDown = keyCode
        postedKeyDownCount += 1

        // Deliberately uninterruptible: see uninterruptibleSleep.
        await uninterruptibleSleep(milliseconds: timing.holdMilliseconds)

        guard let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            // pendingKeyDown stays set so unwind() releases it.
            throw KeystrokeEmitterError.keyboardEventUnavailable
        }
        up.flags = flags
        stamp(up)
        attach(unicode, to: up)
        postHandler(up)
        pendingKeyDown = nil
    }

    /// Returns false when the event could not be created, so the caller can keep
    /// treating the key as still held.
    @discardableResult
    private func postRaw(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, unicode: String?) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        else { return false }
        event.flags = flags
        stamp(event)
        attach(unicode, to: event)
        postHandler(event)
        return true
    }

    /// Real hardware events carry the keyboard type and an explicit autorepeat
    /// flag; synthetic ones default to zero for the former.
    private func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    }

    private func attach(_ string: String?, to event: CGEvent) {
        guard let string else { return }
        let units = Array(string.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    }
}

// MARK: - Unicode payload only (legacy / compatibility)

/// The original VoicePolish strategy, moved here verbatim: key code 0 carrying a
/// Unicode payload.
///
/// Correct for Cocoa text views and Citrix (which reads `NSEvent.characters`),
/// broken for anything that reads the key code, since key code 0 is
/// `kVK_ANSI_A`. Kept as the fallback for when the layout map is unavailable or
/// an input method is active.
///
/// It lives here, next to `KeyCodeEmitter`, rather than staying private on
/// `TextInsertionService`: the engine has to be able to select between the two,
/// and reaching back into the service's private methods would make the service
/// own the engine while the engine calls back into the service.
final class LegacyUnicodeEmitter: KeystrokeEmitting {
    private let source: CGEventSource?
    private let postHandler: (CGEvent) -> Void

    private(set) var postedKeyDownCount = 0
    let stuckModifiers: CGEventFlags = []
    let stuckKeyCode: CGKeyCode? = nil

    init(source: CGEventSource? = nil,
         postHandler: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.source = source
        self.postHandler = postHandler
    }

    func emit(character: Character, timing: KeystrokeTiming) async throws -> KeystrokeEmitResult {
        switch character {
        case "\n", "\r\n", "\r":
            try postVirtualKey(CGKeyCode(kVK_Return))
            return .faithful
        case "\t":
            try postVirtualKey(CGKeyCode(kVK_Tab))
            return .faithful
        default:
            break
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: false)
        else {
            throw KeystrokeEmitterError.keyboardEventUnavailable
        }

        let utf16Units = Array(String(character).utf16)
        utf16Units.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: baseAddress)
        }

        postHandler(keyDown)
        postHandler(keyUp)
        postedKeyDownCount += 1
        return .faithful
    }

    func unwind() {}

    private func postVirtualKey(_ keyCode: CGKeyCode) throws {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw KeystrokeEmitterError.keyboardEventUnavailable
        }
        postHandler(keyDown)
        postHandler(keyUp)
        postedKeyDownCount += 1
    }
}
