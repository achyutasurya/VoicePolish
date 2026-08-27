import Foundation

/// Folds text into characters a remote scan-code client can actually type.
///
/// Two separate jobs:
///  - `fold(_:unreachable:)` rewrites a whole string before typing, driven by
///    what the *live layout* can reach. Used by TextInsertionService.
///  - `foldCharacter(_:)` is the per-character safety net inside KeyCodeEmitter,
///    which runs unconditionally so that turning the string-level fold OFF can
///    never make an accented character degrade to a space.
///
/// Dependency-free by design so `scripts/dev/main.swift` can compile it.
enum TypingTextFolder {

    /// EVERY replacement source is written as a `\u{...}` escape on purpose.
    ///
    /// An earlier revision of this table was authored with literal glyphs and a
    /// round trip through Markdown silently replaced the curly quotes with
    /// straight ones -- producing rules that read U+0027 -> U+0027 and
    /// U+0022 -> U+0022, i.e. two no-ops. The bug was invisible on inspection:
    /// a curly apostrophe in "It's" would still have been typed as
    /// Shift+Option+] into an RDP session, which is a menu accelerator on
    /// Windows and no character at all. Do not "tidy" these into glyphs.
    static let punctuationReplacements: [(String, String)] = [
        ("\u{2014}", "--"),   // — em dash
        ("\u{2013}", "-"),    // – en dash
        ("\u{2012}", "-"),    // ‒ figure dash
        ("\u{2015}", "--"),   // ― horizontal bar
        ("\u{2011}", "-"),    // ‑ non-breaking hyphen
        ("\u{00AD}", ""),     //   soft hyphen
        ("\u{2026}", "..."),  // … ellipsis
        ("\u{2022}", "-"),    // • bullet
        ("\u{00B7}", "-"),    // · middle dot
        ("\u{2018}", "'"),    // ' left single quote
        ("\u{2019}", "'"),    // ' right single quote / apostrophe
        ("\u{201A}", "'"),    // ‚ single low quote
        ("\u{201B}", "'"),    // ‛ single high-reversed quote
        ("\u{2032}", "'"),    // ′ prime
        ("\u{201C}", "\""),   // " left double quote
        ("\u{201D}", "\""),   // " right double quote
        ("\u{201E}", "\""),   // „ double low quote
        ("\u{2033}", "\""),   // ″ double prime
        ("\u{00AB}", "\""),   // « left guillemet
        ("\u{00BB}", "\""),   // » right guillemet
        ("\u{2265}", ">="),   // ≥ -- also Option+. on U.S., the Stop & Type hotkey itself
        ("\u{2264}", "<="),   // ≤ -- Option+,
        ("\u{2260}", "!="),   // ≠ Option+=
        ("\u{00A0}", " "),    // non-breaking space
        ("\u{202F}", " "),    // narrow non-breaking space
        ("\u{2009}", " "),    // thin space
        ("\u{200B}", ""),     // zero-width space
        ("\u{FEFF}", ""),     // zero-width no-break space
    ]

    /// Characters `String.folding(.diacriticInsensitive)` does NOT decompose,
    /// because the diacritic is part of the base letter rather than a combining
    /// mark. Without these, "øre", "straße", "łódź" and "œuvre" would all still
    /// hit the space fallback.
    static let letterReplacements: [(String, String)] = [
        ("\u{00F8}", "o"), ("\u{00D8}", "O"),   // ø Ø
        ("\u{00DF}", "ss"),                      // ß
        ("\u{1E9E}", "SS"),                      // ẞ
        ("\u{0142}", "l"), ("\u{0141}", "L"),   // ł Ł
        ("\u{0111}", "d"), ("\u{0110}", "D"),   // đ Đ
        ("\u{00E6}", "ae"), ("\u{00C6}", "AE"), // æ Æ
        ("\u{0153}", "oe"), ("\u{0152}", "OE"), // œ Œ
        ("\u{00FE}", "th"), ("\u{00DE}", "Th"), // þ Þ
        ("\u{00F0}", "d"), ("\u{00D0}", "D"),   // ð Ð
        ("\u{0131}", "i"),                       // ı dotless i
    ]

    /// Rewrites `text` so a scan-code client can type it.
    ///
    /// `unreachable` is supplied by the caller from the LIVE layout map, so the
    /// fold adapts instead of hard-coding the U.S. answer. That matters: on
    /// ABC-Extended and U.S. International the straight apostrophe is itself a
    /// dead key, so blindly folding U+2019 into U+0027 there would turn a
    /// perfectly typable character into an untypable one.
    static func fold(_ text: String, unreachable: (Character) -> Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for character in text {
            // Reachable without Option? Leave it exactly as the LLM wrote it.
            if !unreachable(character) {
                result.append(character)
                continue
            }
            // The replacement must ALSO be reachable, or the fold makes things
            // worse. On U.S. International the straight apostrophe is a dead key
            // while the curly one is directly typable, so folding U+2019 into
            // U+0027 there would turn a working character into a space.
            if let replacement = replacement(for: character),
               replacement.allSatisfy({ !unreachable($0) }) {
                result.append(replacement)
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Per-character fold used as the emitter's last resort before the space
    /// fallback. Returns nil when nothing better than the original exists.
    static func foldCharacter(_ character: Character) -> String? {
        guard let replacement = replacement(for: character) else { return nil }
        return replacement == String(character) ? nil : replacement
    }

    private static func replacement(for character: Character) -> String? {
        let single = String(character)

        for (from, to) in punctuationReplacements where from == single { return to }
        for (from, to) in letterReplacements where from == single { return to }

        // locale: nil, NOT .current -- a current-locale fold makes results
        // machine-dependent and misbehaves under Turkish collation.
        let diacriticFolded = single.folding(options: .diacriticInsensitive, locale: nil)
        if diacriticFolded != single, !diacriticFolded.isEmpty {
            return diacriticFolded
        }
        return nil
    }
}
