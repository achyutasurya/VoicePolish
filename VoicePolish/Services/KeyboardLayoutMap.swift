import Carbon
import CoreGraphics
import Foundation

/// One physical keystroke: the virtual key code plus the modifiers that must be
/// held for the *current* keyboard layout to produce a particular character.
struct KeyStroke: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// Builds a reverse map (character -> keystroke) by brute-forcing `UCKeyTranslate`
/// over every virtual key code and the four modifier combinations a Latin layout
/// uses to reach printable glyphs.
///
/// This exists because there is no system API to ask "which key produces X?".
/// Posting a real key code matters because scan-code-reading clients read
/// `NSEvent.keyCode` and ignore the attached Unicode string -- which is why
/// posting `virtualKey: 0` made every character arrive as "a" in Microsoft
/// Windows App (key code 0 is `kVK_ANSI_A`).
///
/// Deliberately free of any VoicePolish dependency (no LoggingService, no
/// AppSettings, no AppKit) so `scripts/dev/main.swift` can compile against this
/// exact file rather than a copy.
enum KeyboardLayoutMap {

    /// A key + modifier combination that *starts* a dead-key sequence (Option+E
    /// on U.S., say). Deliberately excluded from `table`: on real hardware it
    /// produces nothing and arms a combining accent.
    struct DeadKey: Equatable, Sendable {
        let keyCode: CGKeyCode
        let carbonModifiers: Int
    }

    struct Snapshot: Sendable {
        let table: [Character: KeyStroke]
        let inputSourceID: String
        let inputSourceName: String
        let keyboardType: UInt32
        let deadKeys: [DeadKey]
        /// True when the current input source had no 'uchr' data and we fell
        /// back to the ASCII-capable layout behind it.
        let usedASCIIFallback: Bool
        /// True when the active input source is an input *method* (Pinyin,
        /// Kotoeri, ...) rather than a plain keyboard layout. Posting real key
        /// codes into an IME starts composition instead of inserting text, so
        /// callers must fall back to the Unicode strategy.
        let inputMethodActive: Bool

        func stroke(for character: Character) -> KeyStroke? { table[character] }

        /// True when the character cannot be typed directly, or can only be
        /// reached by holding Option. Drives the layout-aware fold: hard-coding
        /// the U.S. answer would be wrong on ABC-Extended or U.S. International,
        /// where the straight apostrophe is itself a dead key.
        func requiresOptionOrIsUnreachable(_ character: Character) -> Bool {
            guard let stroke = table[character] else { return true }
            return stroke.flags.contains(.maskAlternate)
        }

        var summary: String {
            "\(inputSourceName) (\(inputSourceID)) · kbdType \(keyboardType) · "
            + "\(table.count) chars mapped · \(deadKeys.count) dead keys"
            + (usedASCIIFallback ? " · ASCII fallback" : "")
        }
    }

    enum BuildError: LocalizedError {
        case noKeyboardLayout
        case noUnicodeLayoutData

        var errorDescription: String? {
            switch self {
            case .noKeyboardLayout:
                return "Could not read the current keyboard layout."
            case .noUnicodeLayoutData:
                return "The current input source has no Unicode key layout data."
            }
        }
    }

    /// Probed in priority order: unmodified beats Shift beats Option. Combined
    /// with the key-code-outer loop below, first-write-wins picks the simplest
    /// way to reach each character.
    private static let probedModifiers: [(carbon: Int, cg: CGEventFlags)] = [
        (0, []),
        (shiftKey, .maskShift),
        (optionKey, .maskAlternate),
        (shiftKey | optionKey, [.maskShift, .maskAlternate]),
    ]

    /// Modifier keys, keys the emitter posts directly by key code, and
    /// `kVK_ISO_Section` -- which on the U.S. layout is the sole producer of
    /// "§" and "±" and is a key that does not exist on ANSI hardware, so
    /// mapping either character to it yields a keystroke the user's keyboard
    /// cannot make.
    private static let excludedKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock), UInt16(kVK_Function),
        UInt16(kVK_Return), UInt16(kVK_Tab), UInt16(kVK_Escape),
        UInt16(kVK_Delete), UInt16(kVK_ForwardDelete),
        UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_ANSI_KeypadClear),
        UInt16(kVK_ISO_Section),
    ]

    /// Fetches the live input source and builds against it.
    ///
    /// Must be called AFTER the target application has been activated: with
    /// "automatically switch to a document's input source" enabled, activating
    /// an app can change the current source.
    static func build() throws -> Snapshot {
        // Microsoft's Windows App resolves scan codes with
        // TISCopyCurrentKeyboardLayoutInputSource (verified with `nm -u`), so use
        // the same source. NOTE: matching functions does not by itself guarantee
        // the round trip -- that requires the local and remote layouts to match.
        var source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        var layoutData = source.flatMap(unicodeLayoutData)
        var usedFallback = false

        if layoutData == nil {
            // A CJK / handwriting input method can be selected with no 'uchr'
            // data attached; fall back to the ASCII-capable layout behind it.
            //
            // Adopt the fallback ONLY if it actually produced layout data.
            // Overwriting `source` unconditionally lost the original, so a layout
            // that merely lacked 'uchr' reported .noKeyboardLayout instead of the
            // accurate .noUnicodeLayoutData.
            if let fallbackSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
               let fallbackData = unicodeLayoutData(fallbackSource) {
                source = fallbackSource
                layoutData = fallbackData
                usedFallback = true
            }
        }

        guard let source else { throw BuildError.noKeyboardLayout }
        guard let layoutData else { throw BuildError.noUnicodeLayoutData }

        return build(
            from: layoutData,
            keyboardType: UInt32(LMGetKbdType()),
            inputSourceID: stringProperty(source, kTISPropertyInputSourceID) ?? "unknown",
            inputSourceName: stringProperty(source, kTISPropertyLocalizedName) ?? "unknown",
            usedASCIIFallback: usedFallback,
            inputMethodActive: currentSourceIsInputMethod()
        )
    }

    /// The real entry point. Split out from `build()` so tests and the dev probe
    /// can feed fixed layout data and stay independent of whatever the developer
    /// happens to have selected.
    static func build(
        from layoutData: CFData,
        keyboardType: UInt32,
        inputSourceID: String = "fixture",
        inputSourceName: String = "fixture",
        usedASCIIFallback: Bool = false,
        inputMethodActive: Bool = false
    ) -> Snapshot {
        var table: [Character: KeyStroke] = [:]
        var deadKeys: [DeadKey] = []

        // KEY CODE IS THE OUTER LOOP, and writes are first-wins.
        //
        // Every keypad code is >= 0x41 and every main-row key that HAS a keypad
        // twin is <= 0x2F, so ascending key codes make the main row win for
        // "0"-"9", ".", "/", "-", "=", "*" and "+". Iterating modifiers on the
        // outside instead flips "*" to KeypadMultiply (0x43) and "+" to
        // KeypadPlus (0x45), because their unmodified keypad forms would be
        // visited before the shifted main-row forms.
        //
        // (kVK_Space 0x31 and kVK_ANSI_Grave 0x32 are main-row keys above 0x2F,
        // but neither has a keypad twin, so the ordering is unaffected.)
        for rawKeyCode in UInt16(0)...UInt16(127) where !excludedKeyCodes.contains(rawKeyCode) {
            for probe in probedModifiers {
                // A fresh state per probe: a dead key otherwise poisons the next call.
                var deadKeyState: UInt32 = 0
                guard let produced = translate(
                    layoutData: layoutData,
                    keyCode: rawKeyCode,
                    carbonModifiers: probe.carbon,
                    keyboardType: keyboardType,
                    deadKeyState: &deadKeyState
                ) else { continue }

                if produced.isEmpty {
                    if deadKeyState != 0 {
                        deadKeys.append(DeadKey(keyCode: CGKeyCode(rawKeyCode),
                                                carbonModifiers: probe.carbon))
                    }
                    continue
                }

                // UCKeyTranslate can return several characters; only a single
                // one is a usable one-keystroke mapping.
                guard produced.count == 1,
                      let character = produced.first,
                      isTypable(character) else { continue }

                if table[character] == nil {
                    table[character] = KeyStroke(keyCode: CGKeyCode(rawKeyCode), flags: probe.cg)
                }
            }
        }

        return Snapshot(
            table: table,
            inputSourceID: inputSourceID,
            inputSourceName: inputSourceName,
            keyboardType: keyboardType,
            deadKeys: deadKeys,
            usedASCIIFallback: usedASCIIFallback,
            inputMethodActive: inputMethodActive
        )
    }

    /// Forward translation.
    ///
    /// `keyTranslateOptions` is deliberately 0 -- dead keys ENABLED. With
    /// `kUCKeyTranslateNoDeadKeysMask` ("Prevents setting any new dead-key
    /// states") Option+E on U.S. returns a standalone acute accent, and we would
    /// map "´" to a keystroke that on real hardware produces nothing at all.
    /// With 0, a dead key instead reports noErr + length 0 + non-zero state.
    static func translate(
        layoutData: CFData,
        keyCode: UInt16,
        carbonModifiers: Int,
        keyboardType: UInt32,
        deadKeyState: inout UInt32
    ) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        var buffer = [UniChar](repeating: 0, count: 8)
        var length = 0

        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            layoutPointer -> OSStatus in
            UCKeyTranslate(
                layoutPointer,
                keyCode,
                UInt16(kUCKeyActionDown),
                // UCKeyTranslate wants the HIGH BYTE of the classic Event
                // Manager modifiers: shiftKey (0x0200) -> 0x02, optionKey
                // (0x0800) -> 0x08.
                UInt32((carbonModifiers >> 8) & 0xFF),
                keyboardType,
                0,
                &deadKeyState,
                buffer.count,
                &length,
                &buffer
            )
        }
        guard status == noErr else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    /// True when the active input source is an input *method* rather than a
    /// keyboard layout. Real key codes drive IME composition, so the caller must
    /// use the Unicode strategy instead.
    static func currentSourceIsInputMethod() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return false }
        let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
    }

    /// The live input source identifier, read fresh. Logged immediately before
    /// the typing loop so a per-app input-source switch is diagnosable.
    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        else { return nil }
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    private static func isTypable(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }   // control characters
        if (0xF700...0xF8FF).contains(scalar.value) { return false }      // NSEvent function keys
        return true
    }

    private static func unicodeLayoutData(_ source: TISInputSource) -> CFData? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
