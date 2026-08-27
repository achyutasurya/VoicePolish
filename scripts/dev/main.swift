// Offline validation harness for the Stop & Type keystroke path.
//
// Compiles against the REAL source files, not copies, which is why
// KeyboardLayoutMap.swift / KeystrokeEmitter.swift / TypingTextFolder.swift must
// stay free of LoggingService / AppSettings / ErrorService / AppKit imports:
//
//   swiftc -O scripts/dev/main.swift \
//     VoicePolish/Services/KeyboardLayoutMap.swift \
//     VoicePolish/Services/KeystrokeEmitter.swift \
//     VoicePolish/Services/TypingTextFolder.swift -o /tmp/probe_typing
//
// This file MUST be called main.swift: in a multi-file swiftc invocation top
// level code is only legal there ("expressions are not allowed at the top level").
//
// Modes:
//   --check                 offline layout assertions, no permission needed
//   --tap-verify [text]     swallow our own events with a CGEventTap and decode
//                           them back to text -- zero side effects
//   --tap-cancel            cancel mid-run, assert nothing is left held
//
// --tap-verify / --tap-cancel need Accessibility, inherited from the terminal
// they run in. Grant Terminal / VS Code, not this binary.

import Carbon
import CoreGraphics
import Foundation

// MARK: - Tiny assertion harness

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok    \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL  \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func expectStroke(_ snapshot: KeyboardLayoutMap.Snapshot,
                  _ character: Character,
                  keyCode: Int,
                  flags: CGEventFlags,
                  _ label: String) {
    guard let stroke = snapshot.stroke(for: character) else {
        checks += 1; failures += 1
        print("  FAIL  \(label) — '\(character)' is not in the table at all")
        return
    }
    expect(stroke.keyCode == CGKeyCode(keyCode) && stroke.flags == flags, label,
           "got keyCode \(stroke.keyCode) flags \(stroke.flags.rawValue), wanted \(keyCode)/\(flags.rawValue)")
}

// MARK: - --check

func runCheck() {
    let snapshot: KeyboardLayoutMap.Snapshot
    do { snapshot = try KeyboardLayoutMap.build() } catch {
        print("FAILED to build layout map: \(error)")
        exit(1)
    }

    print("Layout: \(snapshot.summary)")
    print("")

    let isUS = snapshot.inputSourceID == "com.apple.keylayout.US"
        || snapshot.inputSourceID == "com.apple.keylayout.ABC"
    guard isUS else {
        print("Layout-specific assertions skipped (needs U.S. / ABC, have \(snapshot.inputSourceID)).")
        print("Running only layout-independent checks.")
        runLayoutIndependentChecks(snapshot)
        runFoldAcrossInstalledLayouts()
        runUnwindScopeCheck(snapshot)
        runFlagFidelityCheck(snapshot)
        runDeletionCheck(snapshot)
        summarise()
        return
    }

    print("Basic strokes")
    expectStroke(snapshot, "a", keyCode: kVK_ANSI_A, flags: [], "a -> kVK_ANSI_A (0), no modifier")
    expectStroke(snapshot, "A", keyCode: kVK_ANSI_A, flags: .maskShift, "A -> kVK_ANSI_A (0) + shift")
    expectStroke(snapshot, "1", keyCode: kVK_ANSI_1, flags: [], "1 -> kVK_ANSI_1 (18)")
    expectStroke(snapshot, "!", keyCode: kVK_ANSI_1, flags: .maskShift, "! -> kVK_ANSI_1 (18) + shift")

    print("")
    print("Main row must beat the keypad (regression: loop nesting order)")
    expectStroke(snapshot, "*", keyCode: kVK_ANSI_8, flags: .maskShift, "* -> main row 8+shift, NOT KeypadMultiply (67)")
    expectStroke(snapshot, "+", keyCode: kVK_ANSI_Equal, flags: .maskShift, "+ -> main row =+shift, NOT KeypadPlus (69)")
    expectStroke(snapshot, "/", keyCode: kVK_ANSI_Slash, flags: [], "/ -> main row, NOT KeypadDivide (75)")
    expectStroke(snapshot, ".", keyCode: kVK_ANSI_Period, flags: [], ". -> main row, NOT KeypadDecimal (65)")
    expectStroke(snapshot, "-", keyCode: kVK_ANSI_Minus, flags: [], "- -> main row, NOT KeypadMinus (78)")
    let keypadCodes = Set([65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92])
    for digit in "0123456789" {
        guard let stroke = snapshot.stroke(for: digit) else { continue }
        expect(!keypadCodes.contains(Int(stroke.keyCode)), "\(digit) is on the main row",
               "got keyCode \(stroke.keyCode)")
    }

    print("")
    print("Dead keys")
    expect(!snapshot.deadKeys.isEmpty, "dead keys were detected",
           "found \(snapshot.deadKeys.count)")
    // NOT "acute is absent": Shift+Option+E produces U+00B4 with deadKeyState 0,
    // so the CHARACTER is reachable even though the Option+E POSITION is a dead
    // key and is excluded. The real invariant is that its stroke is the
    // non-dead one.
    if let acute = snapshot.stroke(for: "\u{00B4}") {
        expect(acute.flags.contains(.maskShift) && acute.flags.contains(.maskAlternate),
               "acute U+00B4 maps to the NON-dead position (shift+option)",
               "got flags \(acute.flags.rawValue)")
    } else {
        print("  note  acute U+00B4 not in table on this layout")
    }

    print("")
    print("Exclusions")
    expect(snapshot.stroke(for: "\u{00A7}") == nil
           || snapshot.stroke(for: "\u{00A7}")!.keyCode != CGKeyCode(kVK_ISO_Section),
           "section sign never maps to kVK_ISO_Section (10)")

    print("")
    print("Hotkey collision")
    if let ge = snapshot.stroke(for: "\u{2265}") {
        expect(ge.keyCode == CGKeyCode(kVK_ANSI_Period) && ge.flags.contains(.maskAlternate),
               "U+2265 is Option+Period — the Stop & Type binding, hence the fold",
               "got keyCode \(ge.keyCode)")
    }

    runLayoutIndependentChecks(snapshot)
    runFoldAcrossInstalledLayouts()
    runUnwindScopeCheck(snapshot)
    runFlagFidelityCheck(snapshot)
    runDeletionCheck(snapshot)
    summarise()
}

func runLayoutIndependentChecks(_ snapshot: KeyboardLayoutMap.Snapshot) {
    print("")
    print("Table hygiene")
    expect(snapshot.stroke(for: "\n") == nil, "newline is not in the table")
    expect(snapshot.stroke(for: "\t") == nil, "tab is not in the table")
    expect(snapshot.table.keys.allSatisfy { char in
        guard let scalar = char.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }, "no control characters in the table")

    print("")
    print("Fold — the regression that nearly shipped")
    // These MUST change. An earlier revision had rules that read U+0027 -> U+0027
    // because a Markdown round trip laundered the curly quotes into straight ones.
    let curlyApostrophe = "It\u{2019}s"
    let foldedApostrophe = TypingTextFolder.fold(curlyApostrophe) { snapshot.requiresOptionOrIsUnreachable($0) }
    expect(foldedApostrophe == "It's", "curly apostrophe U+2019 folds to ASCII",
           "got \(Array(foldedApostrophe.unicodeScalars).map { "U+\(String(format: "%04X", $0.value))" }.joined(separator: " "))")

    let curlyQuotes = "\u{201C}hi\u{201D}"
    let foldedQuotes = TypingTextFolder.fold(curlyQuotes) { snapshot.requiresOptionOrIsUnreachable($0) }
    expect(foldedQuotes == "\"hi\"", "curly double quotes fold to ASCII", "got \(foldedQuotes)")

    let dashes = "a\u{2014}b\u{2013}c\u{2026}"
    let foldedDashes = TypingTextFolder.fold(dashes) { snapshot.requiresOptionOrIsUnreachable($0) }
    expect(foldedDashes == "a--b-c...", "em dash / en dash / ellipsis fold", "got \(foldedDashes)")

    print("")
    print("Accented and special letters reach a real key, not the space fallback")
    for word in ["caf\u{00E9}", "jalape\u{00F1}o", "Zo\u{00EB}", "\u{00F8}re", "stra\u{00DF}e", "\u{0142}\u{00F3}d\u{017A}", "\u{0153}uvre"] {
        let reachable = word.allSatisfy { character in
            if snapshot.stroke(for: character) != nil { return true }
            guard let folded = TypingTextFolder.foldCharacter(character) else { return false }
            return folded.allSatisfy { snapshot.stroke(for: $0) != nil }
        }
        expect(reachable, "\(word) is typable without degrading to a space")
    }

    print("")
    print("Timing")
    for (delay, wantHold) in [(90, 40), (50, 22), (20, 10)] {
        let timing = KeystrokeTiming.forInterKeyDelay(delay)
        expect(timing.holdMilliseconds == wantHold,
               "interKeyDelay \(delay)ms -> hold \(wantHold)ms", "got \(timing.holdMilliseconds)")
        expect(timing.holdMilliseconds <= delay,
               "hold never exceeds the inter-key budget at \(delay)ms")
    }
}


// MARK: - Offline emitter checks (spy postHandler — no permissions needed)

func runBlocking(_ body: @escaping @Sendable () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task.detached { await body(); sem.signal() }
    sem.wait()
}

struct Posted {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
}

func spyEmitter(_ snapshot: KeyboardLayoutMap.Snapshot,
                _ sink: @escaping (Posted) -> Void) -> KeyCodeEmitter? {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return nil }
    return KeyCodeEmitter(source: src, layout: snapshot) { event in
        sink(Posted(type: event.type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags))
    }
}

/// FIX 1 regression. Layout-independent invariant: the fold must never emit a
/// character the emitter cannot type. This is the assertion whose absence let
/// the U.S. International bug ship (curly apostrophe typable, straight one a
/// dead key -> the fold produced an untypable character).
func runFoldAcrossInstalledLayouts() {
    print("")
    print("Fold invariant across every installed keyboard layout")

    let props = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    guard let list = TISCreateInputSourceList(props, true)?.takeRetainedValue() as? [TISInputSource] else {
        print("  note  could not enumerate input sources")
        return
    }

    let sample = "It\u{2019}s \u{201C}fine\u{201D} \u{2014} really\u{2026} caf\u{00E9} stra\u{00DF}e \u{2265} \u{2264} \u{2022} \u{00A0}x"
    var tested = 0

    for src in list {
        guard let dataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { continue }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        let namePtr = TISGetInputSourceProperty(src, kTISPropertyLocalizedName)
        let name = namePtr.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"

        let snap = KeyboardLayoutMap.build(from: data, keyboardType: UInt32(LMGetKbdType()))
        guard !snap.table.isEmpty else { continue }
        tested += 1

        let folded = TypingTextFolder.fold(sample) { snap.requiresOptionOrIsUnreachable($0) }
        // Every character the fold EMITTED must either be typable, or have been
        // untypable already in the input (the fold is not obliged to fix those).
        let leaked = folded.filter { snap.stroke(for: $0) == nil && $0 != " " && !sample.contains($0) }
        expect(leaked.isEmpty, "fold introduces no untypable character on \(name)",
               "leaked: \(leaked.map { "U+\(String(format: "%04X", $0.unicodeScalars.first!.value))" }.joined(separator: " "))")
    }
    expect(tested > 0, "at least one installed layout was exercised", "tested \(tested)")
}

/// FIX 2 regression. A run that never pressed Command must never post a Command
/// event — unwind() previously drained whatever global HID state reported as
/// down, which on the Cmd+[ abort path is the user's own finger.
func runUnwindScopeCheck(_ snapshot: KeyboardLayoutMap.Snapshot) {
    print("")
    print("unwind() only touches modifiers this run pressed")

    var posted: [Posted] = []
    guard let emitter = spyEmitter(snapshot, { posted.append($0) }) else {
        print("  note  no event source"); return
    }
    runBlocking {
        for ch in "ABC abc" { _ = try? await emitter.emit(character: ch, timing: .immediate) }
        emitter.unwind()
    }

    let cmdCodes: Set<Int64> = [Int64(kVK_Command), Int64(kVK_RightCommand)]
    let ctrlCodes: Set<Int64> = [Int64(kVK_Control), Int64(kVK_RightControl)]
    expect(!posted.contains { cmdCodes.contains($0.keyCode) }, "zero Command events posted")
    expect(!posted.contains { ctrlCodes.contains($0.keyCode) }, "zero Control events posted")
    expect(emitter.stuckModifiers.isEmpty, "no modifier reported stuck")
    expect(emitter.stuckKeyCode == nil, "no character key reported stuck")

    // FIX 6 regression: unwind() is idempotent, so the engine can call it
    // explicitly AND keep the defer as a backstop.
    let before = posted.count
    emitter.unwind()
    expect(posted.count == before, "second unwind() posts nothing (idempotent)",
           "posted \(posted.count - before) extra events")
}

/// FIX 4 regression. The character event must advertise exactly the modifiers
/// actually held — Shift for a capital, nothing for a lowercase.
func runFlagFidelityCheck(_ snapshot: KeyboardLayoutMap.Snapshot) {
    print("")
    print("Character events carry the modifiers actually held")

    var posted: [Posted] = []
    guard let emitter = spyEmitter(snapshot, { posted.append($0) }) else { return }
    runBlocking {
        for ch in "aA" { _ = try? await emitter.emit(character: ch, timing: .immediate) }
        emitter.unwind()
    }

    let charDowns = posted.filter {
        $0.type == .keyDown && !modifierKeyCodes.contains($0.keyCode)
    }
    expect(charDowns.count == 2, "two character key-downs", "got \(charDowns.count)")
    if charDowns.count == 2 {
        expect(!charDowns[0].flags.contains(.maskShift), "lowercase 'a' carries no Shift")
        expect(charDowns[1].flags.contains(.maskShift), "capital 'A' carries Shift")
    }
}

/// FIX 10 regression. Zero-width and soft-hyphen characters are deletions: they
/// must post nothing and must not be counted as typed.
func runDeletionCheck(_ snapshot: KeyboardLayoutMap.Snapshot) {
    print("")
    print("Zero-width / soft-hyphen characters are deletions, not typed characters")

    for scalar in ["\u{00AD}", "\u{200B}", "\u{FEFF}"] {
        var posted: [Posted] = []
        guard let emitter = spyEmitter(snapshot, { posted.append($0) }) else { return }
        final class ResultBox: @unchecked Sendable { var value: KeystrokeEmitResult? }
        let box = ResultBox()
        runBlocking {
            box.value = try? await emitter.emit(character: Character(scalar), timing: .immediate)
            emitter.unwind()
        }
        let result = box.value
        let code = String(format: "U+%04X", scalar.unicodeScalars.first!.value)
        if case .deleted = result { expect(true, "\(code) reports .deleted") }
        else { expect(false, "\(code) reports .deleted", "got \(String(describing: result))") }
        expect(posted.isEmpty, "\(code) posts no events", "posted \(posted.count)")
    }
}

func summarise() {
    print("")
    print(failures == 0 ? "PASS — \(checks) checks" : "FAIL — \(failures) of \(checks) checks failed")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Event tap capture

final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)] = []

    func append(_ type: CGEventType, _ keyCode: Int64, _ flags: CGEventFlags) {
        lock.lock(); defer { lock.unlock() }
        events.append((type, keyCode, flags))
    }

    var snapshot: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

let capture = Capture()
nonisolated(unsafe) var runFinished = false

func installSwallowingTap() -> CFMachPort? {
    let mask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, _ in
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            capture.append(type, keyCode, event.flags)
            // Swallow: nothing reaches any application.
            return nil
        },
        userInfo: nil
    ) else { return nil }

    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return tap
}

let modifierKeyCodes: Set<Int64> = [
    Int64(kVK_Shift), Int64(kVK_RightShift),
    Int64(kVK_Option), Int64(kVK_RightOption),
    Int64(kVK_Control), Int64(kVK_RightControl),
    Int64(kVK_Command), Int64(kVK_RightCommand),
    Int64(kVK_CapsLock),
]

/// Decode the captured stream back to text using the same layout the emitter used.
func decode(_ events: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)],
            layoutData: CFData, keyboardType: UInt32) -> String {
    var out = ""
    for event in events where event.type == .keyDown {
        if modifierKeyCodes.contains(event.keyCode) { continue }
        if event.keyCode == Int64(kVK_Return) { out.append("\n"); continue }
        if event.keyCode == Int64(kVK_Tab) { out.append("\t"); continue }

        var carbonModifiers = 0
        if event.flags.contains(.maskShift) { carbonModifiers |= shiftKey }
        if event.flags.contains(.maskAlternate) { carbonModifiers |= optionKey }

        var deadKeyState: UInt32 = 0
        if let produced = KeyboardLayoutMap.translate(
            layoutData: layoutData,
            keyCode: UInt16(event.keyCode),
            carbonModifiers: carbonModifiers,
            keyboardType: keyboardType,
            deadKeyState: &deadKeyState
        ), !produced.isEmpty {
            out += produced
        }
    }
    return out
}

func balanceReport(_ events: [(type: CGEventType, keyCode: Int64, flags: CGEventFlags)]) -> [Int64: Int] {
    var balance: [Int64: Int] = [:]
    for event in events {
        switch event.type {
        case .keyDown: balance[event.keyCode, default: 0] += 1
        case .keyUp: balance[event.keyCode, default: 0] -= 1
        default: break
        }
    }
    return balance.filter { $0.value != 0 }
}

func pumpUntilFinished(timeout: TimeInterval = 120) {
    let deadline = Date().addingTimeInterval(timeout)
    while !runFinished && Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.02, true)
    }
    // Let trailing events drain through the tap.
    for _ in 0..<15 { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
}

func requireLayout() -> (KeyboardLayoutMap.Snapshot, CFData, UInt32) {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
        print("Could not read the current keyboard layout."); exit(1)
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    let keyboardType = UInt32(LMGetKbdType())
    do {
        return (try KeyboardLayoutMap.build(), layoutData, keyboardType)
    } catch {
        print("Could not build layout map: \(error)"); exit(1)
    }
}

// MARK: - --tap-verify

func runTapVerify(_ text: String) {
    let (snapshot, layoutData, keyboardType) = requireLayout()
    print("Layout: \(snapshot.summary)")

    let folded = TypingTextFolder.fold(text) { snapshot.requiresOptionOrIsUnreachable($0) }
    print("Input  : \(text)")
    if folded != text { print("Folded : \(folded)") }

    guard let tap = installSwallowingTap() else {
        print("")
        print("Could not create the event tap. Grant Accessibility to this terminal:")
        print("  System Settings > Privacy & Security > Accessibility")
        exit(1)
    }
    defer { CGEvent.tapEnable(tap: tap, enable: false) }

    guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
        print("No event source."); exit(1)
    }
    eventSource.localEventsSuppressionInterval = 0

    let emitter = KeyCodeEmitter(source: eventSource, layout: snapshot)
    let timing = KeystrokeTiming.forInterKeyDelay(20)

    Task.detached {
        for character in folded {
            _ = try? await emitter.emit(character: character, timing: timing)
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        emitter.unwind()
        runFinished = true
    }
    pumpUntilFinished()

    let events = capture.snapshot
    let decoded = decode(events, layoutData: layoutData, keyboardType: keyboardType)
    print("Decoded: \(decoded)")
    print("")
    print("Captured \(events.count) events, \(events.filter { $0.type == .keyDown }.count) key-downs")

    expect(decoded == folded, "round trip matches",
           decoded == folded ? "" : "expected \(folded.debugDescription), got \(decoded.debugDescription)")
    expect(balanceReport(events).isEmpty, "every key-down has a matching key-up",
           "unbalanced: \(balanceReport(events))")
    expect(emitter.stuckModifiers.isEmpty, "no modifier left held")
    expect(!events.contains { $0.type == .keyDown && $0.keyCode == 0 && !decoded.contains("a") && !decoded.contains("A") },
           "key code 0 only appears for a real 'a'")
    summarise()
}

// MARK: - --tap-cancel

func runTapCancel() {
    let (snapshot, _, _) = requireLayout()
    print("Layout: \(snapshot.summary)")

    guard let tap = installSwallowingTap() else {
        print("Could not create the event tap. Grant Accessibility to this terminal.")
        exit(1)
    }
    defer { CGEvent.tapEnable(tap: tap, enable: false) }

    guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
        print("No event source."); exit(1)
    }

    // Capitals force Shift to be held, which is what must never be stranded.
    let text = "ABCdefGHI JKL!mno"
    let timing = KeystrokeTiming.forInterKeyDelay(60)

    for cancelAfter in [1, 3, 5, 8, 12] {
        runFinished = false
        let emitter = KeyCodeEmitter(source: eventSource, layout: snapshot)

        Task.detached {
            var index = 0
            for character in text {
                if index >= cancelAfter { break }
                _ = try? await emitter.emit(character: character, timing: timing)
                index += 1
            }
            // Simulates the engine's `defer { emitter.unwind() }` firing on cancel.
            emitter.unwind()
            runFinished = true
        }
        pumpUntilFinished(timeout: 30)

        expect(emitter.stuckModifiers.isEmpty, "cancel after \(cancelAfter) chars leaves no modifier held",
               "stuck: \(emitter.stuckModifiers.rawValue)")
    }

    let balance = balanceReport(capture.snapshot)
    expect(balance.isEmpty, "no key left down across all cancel points", "unbalanced: \(balance)")
    summarise()
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--check", nil:
    runCheck()
case "--tap-verify":
    // Real LLM prose by default: a curly apostrophe and a real em dash are
    // exactly what a synthetic "Hi!\n" test would have missed.
    let text = arguments.count > 1
        ? arguments[1]
        : "Hello, World! It\u{2019}s 42% \u{2014} done."
    runTapVerify(text)
case "--tap-cancel":
    runTapCancel()
default:
    print("usage: probe_typing [--check | --tap-verify [text] | --tap-cancel]")
    exit(2)
}
