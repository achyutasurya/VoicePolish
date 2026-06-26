import Foundation
import SwiftUI

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum CitrixTypingSpeedPreset: String, CaseIterable, Identifiable {
        case wpm50
        case wpm80
        case wpm120

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wpm50: return "50 words/min"
            case .wpm80: return "80 words/min"
            case .wpm120: return "120 words/min"
            }
        }

        var detailText: String {
            switch self {
            case .wpm50:
                return "Safest profile with random 150-250ms pause between words"
            case .wpm80:
                return "Faster key cadence with random 150-250ms pause between words"
            case .wpm120:
                return "Fastest key cadence with random 150-250ms pause between words"
            }
        }

        var interKeyDelayMs: Int {
            switch self {
            case .wpm50: return 90
            case .wpm80: return 50
            case .wpm120: return 20
            }
        }

        var newlineDelayMs: Int {
            switch self {
            case .wpm50: return 400
            case .wpm80: return 400
            case .wpm120: return 400
            }
        }

        var chunkSize: Int {
            switch self {
            case .wpm50: return 40
            case .wpm80: return 80
            case .wpm120: return 120
            }
        }

        var chunkPauseMs: Int {
            switch self {
            case .wpm50: return 350
            case .wpm80: return 240
            case .wpm120: return 180
            }
        }

        var wordPauseMinMs: Int { 150 }
        var wordPauseMaxMs: Int { 250 }
        var charJitterMs: Int { 25 }

        static func inferFrom(interKeyDelayMs: Int) -> Self {
            switch interKeyDelayMs {
            case 975...: return .wpm50 // Legacy: 50 chars/min
            case 575...: return .wpm80 // Legacy: 80 chars/min
            case 250...: return .wpm120 // Legacy: 150 chars/min
            case 60...: return .wpm50
            case 30...: return .wpm80
            default: return .wpm120
            }
        }
    }

    /// Note: @Observable does not properly track changes to computed properties backed by UserDefaults.
    /// Views that need reactive updates should use local @State variables that explicitly read from
    /// these properties, rather than relying on automatic observation. See LLMModelPickerView for example.

    /// Old default prompt — used to detect and auto-migrate to the new one.
    private static let oldDefaultPrompt = "Rewrite the text we received from audio, by considering the grammar of the language"
    private static let keyCitrixTypingPreset = "citrixTypingSpeedPreset"
    private static let keyCitrixInterKeyDelayMs = "citrixTypingInterKeyDelayMs"
    private static let keyCitrixNewlineDelayMs = "citrixTypingNewlineDelayMs"
    private static let keyCitrixChunkSize = "citrixTypingChunkSize"
    private static let keyCitrixChunkPauseMs = "citrixTypingChunkPauseMs"
    private static let keyCitrixWordPauseMinMs = "citrixTypingWordPauseMinMs"
    private static let keyCitrixWordPauseMaxMs = "citrixTypingWordPauseMaxMs"
    private static let keyCitrixCharJitterMs = "citrixTypingCharJitterMs"

    static let defaultSystemPrompt = """
        You are a speech-to-text cleanup assistant. You receive raw transcriptions from voice recordings. \
        Your job is to output ONLY the cleaned-up text — fix grammar, punctuation, capitalization, and remove filler words (um, uh, like, you know). \
        Preserve the speaker's original meaning, tone, and intent exactly. Do not add, remove, or rephrase ideas. \
        Do not add any commentary, explanations, labels, quotes, or markdown formatting. \
        Output nothing except the corrected text itself, ready to be pasted directly.
        """

    private init() {
        // Auto-migrate: if the stored prompt is the old default, replace with the new one
        if let stored = UserDefaults.standard.string(forKey: "systemPrompt"),
           stored == Self.oldDefaultPrompt {
            UserDefaults.standard.set(Self.defaultSystemPrompt, forKey: "systemPrompt")
        }

        initializeCitrixTypingPresetIfNeeded()
    }

    // MARK: - Persisted Settings

    var deepgramAPIKey: String {
        get { UserDefaults.standard.string(forKey: "deepgramAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "deepgramAPIKey") }
    }

    var deepgramModel: String {
        get { UserDefaults.standard.string(forKey: "deepgramModel") ?? DeepgramModel.defaultModel.id }
        set { UserDefaults.standard.set(newValue, forKey: "deepgramModel") }
    }

    var deepgramVocabularyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "deepgramVocabularyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "deepgramVocabularyEnabled") }
    }

    var deepgramKeyterms: [String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "deepgramKeyterms"),
                  let terms = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return terms
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "deepgramKeyterms")
            }
        }
    }

    var sendToLLMEnabled: Bool {
        get {
            // Default to true — UserDefaults.bool returns false for missing keys,
            // which would silently break LLM processing for existing users on upgrade.
            if UserDefaults.standard.object(forKey: "sendToLLMEnabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "sendToLLMEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "sendToLLMEnabled") }
    }

    // MARK: - Recordings Archive (v0.3.30)

    /// Master switch for archiving recorded audio to disk (default on).
    var audioArchivalEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "audioArchivalEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "audioArchivalEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "audioArchivalEnabled") }
    }

    /// Save scope: true = archive both successful AND failed recordings (default);
    /// false = keep audio only for failures (the Retry-from-history use-case).
    var archiveSuccessfulRecordings: Bool {
        get {
            if UserDefaults.standard.object(forKey: "archiveSuccessfulRecordings") == nil { return true }
            return UserDefaults.standard.bool(forKey: "archiveSuccessfulRecordings")
        }
        set { UserDefaults.standard.set(newValue, forKey: "archiveSuccessfulRecordings") }
    }

    /// Audio retention policy, stored as a mode string + value int (UserDefaults can't
    /// hold an associated-value enum). Default: 7-day age-out (history *text* is kept
    /// forever; only the WAV files are pruned).
    var audioRetentionPolicy: AudioRetentionPolicy {
        get {
            let mode = UserDefaults.standard.string(forKey: "audioRetentionMode") ?? "maxAgeDays"
            let value = UserDefaults.standard.object(forKey: "audioRetentionValue") as? Int ?? 7
            switch mode {
            case "keepAll": return .keepAll
            case "lastN": return .lastN(max(1, value))
            default: return .maxAgeDays(max(1, value))
            }
        }
        set {
            switch newValue {
            case .keepAll:
                UserDefaults.standard.set("keepAll", forKey: "audioRetentionMode")
            case .lastN(let n):
                UserDefaults.standard.set("lastN", forKey: "audioRetentionMode")
                UserDefaults.standard.set(n, forKey: "audioRetentionValue")
            case .maxAgeDays(let d):
                UserDefaults.standard.set("maxAgeDays", forKey: "audioRetentionMode")
                UserDefaults.standard.set(d, forKey: "audioRetentionValue")
            }
        }
    }

    var openRouterAPIKey: String {
        get { UserDefaults.standard.string(forKey: "openRouterAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openRouterAPIKey") }
    }

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "selectedModel") ?? LLMModel.defaultModel.id }
        set { UserDefaults.standard.set(newValue, forKey: "selectedModel") }
    }

    var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: "systemPrompt") ?? Self.defaultSystemPrompt }
        set { UserDefaults.standard.set(newValue, forKey: "systemPrompt") }
    }

    var temperature: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "temperature")
            return value > 0 ? value : 0.3 // Default: 0.3 for deterministic cleanup
        }
        set { UserDefaults.standard.set(newValue, forKey: "temperature") }
    }

    var popupX: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "popupX")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "popupX") }
    }

    var popupY: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "popupY")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "popupY") }
    }

    var citrixTypingInterKeyDelayMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.keyCitrixInterKeyDelayMs)
            return value > 0 ? value : CitrixTypingSpeedPreset.wpm50.interKeyDelayMs
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.keyCitrixInterKeyDelayMs) }
    }

    var citrixTypingNewlineDelayMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.keyCitrixNewlineDelayMs)
            return value > 0 ? value : CitrixTypingSpeedPreset.wpm50.newlineDelayMs
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.keyCitrixNewlineDelayMs) }
    }

    var citrixTypingChunkSize: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.keyCitrixChunkSize)
            return value > 0 ? value : CitrixTypingSpeedPreset.wpm50.chunkSize
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Self.keyCitrixChunkSize) }
    }

    var citrixTypingChunkPauseMs: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.keyCitrixChunkPauseMs)
            return value > 0 ? value : CitrixTypingSpeedPreset.wpm50.chunkPauseMs
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.keyCitrixChunkPauseMs) }
    }

    var citrixTypingWordPauseMinMs: Int {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.keyCitrixWordPauseMinMs) == nil {
                return 150
            }
            let value = defaults.integer(forKey: Self.keyCitrixWordPauseMinMs)
            return max(0, value)
        }
        set {
            let clamped = max(0, newValue)
            UserDefaults.standard.set(clamped, forKey: Self.keyCitrixWordPauseMinMs)
            if clamped > citrixTypingWordPauseMaxMs {
                UserDefaults.standard.set(clamped, forKey: Self.keyCitrixWordPauseMaxMs)
            }
        }
    }

    var citrixTypingWordPauseMaxMs: Int {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.keyCitrixWordPauseMaxMs) == nil {
                return 250
            }
            let value = defaults.integer(forKey: Self.keyCitrixWordPauseMaxMs)
            return max(citrixTypingWordPauseMinMs, value)
        }
        set { UserDefaults.standard.set(max(citrixTypingWordPauseMinMs, newValue), forKey: Self.keyCitrixWordPauseMaxMs) }
    }

    var citrixTypingCharJitterMs: Int {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.keyCitrixCharJitterMs) == nil {
                return CitrixTypingSpeedPreset.wpm50.charJitterMs
            }
            return max(0, defaults.integer(forKey: Self.keyCitrixCharJitterMs))
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.keyCitrixCharJitterMs) }
    }

    var citrixTypingSpeedPreset: CitrixTypingSpeedPreset {
        get {
            initializeCitrixTypingPresetIfNeeded()
            guard let rawValue = UserDefaults.standard.string(forKey: Self.keyCitrixTypingPreset),
                  let preset = mapCitrixPreset(rawValue: rawValue)
            else {
                return .wpm50
            }
            return preset
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.keyCitrixTypingPreset)
            applyCitrixTypingPreset(newValue)
        }
    }

    func applyCitrixTypingPreset(_ preset: CitrixTypingSpeedPreset) {
        citrixTypingInterKeyDelayMs = preset.interKeyDelayMs
        citrixTypingNewlineDelayMs = preset.newlineDelayMs
        citrixTypingChunkSize = preset.chunkSize
        citrixTypingChunkPauseMs = preset.chunkPauseMs
        citrixTypingWordPauseMinMs = preset.wordPauseMinMs
        citrixTypingWordPauseMaxMs = preset.wordPauseMaxMs
        citrixTypingCharJitterMs = preset.charJitterMs
    }

    private func initializeCitrixTypingPresetIfNeeded() {
        let defaults = UserDefaults.standard
        if let existingRaw = defaults.string(forKey: Self.keyCitrixTypingPreset) {
            if let mapped = mapCitrixPreset(rawValue: existingRaw),
               existingRaw != mapped.rawValue {
                defaults.set(mapped.rawValue, forKey: Self.keyCitrixTypingPreset)
                applyCitrixTypingPreset(mapped)
                return
            }

            if let mapped = mapCitrixPreset(rawValue: existingRaw) {
                migrateLegacyCitrixPauseDefaultsIfNeeded(for: mapped, defaults: defaults)
            }
            return
        }

        let hasAnyTimingConfiguration =
            defaults.object(forKey: Self.keyCitrixInterKeyDelayMs) != nil ||
            defaults.object(forKey: Self.keyCitrixNewlineDelayMs) != nil ||
            defaults.object(forKey: Self.keyCitrixChunkSize) != nil ||
            defaults.object(forKey: Self.keyCitrixChunkPauseMs) != nil

        if hasAnyTimingConfiguration {
            let inferredPreset = CitrixTypingSpeedPreset.inferFrom(
                interKeyDelayMs: defaults.integer(forKey: Self.keyCitrixInterKeyDelayMs)
            )
            defaults.set(inferredPreset.rawValue, forKey: Self.keyCitrixTypingPreset)
            applyCitrixTypingPreset(inferredPreset)
            return
        }

        defaults.set(CitrixTypingSpeedPreset.wpm50.rawValue, forKey: Self.keyCitrixTypingPreset)
        applyCitrixTypingPreset(.wpm50)
    }

    private func migrateLegacyCitrixPauseDefaultsIfNeeded(
        for preset: CitrixTypingSpeedPreset,
        defaults: UserDefaults
    ) {
        let legacyNewlineDelayMs: Int
        switch preset {
        case .wpm50:
            legacyNewlineDelayMs = 220
        case .wpm80:
            legacyNewlineDelayMs = 170
        case .wpm120:
            legacyNewlineDelayMs = 120
        }

        if defaults.object(forKey: Self.keyCitrixNewlineDelayMs) != nil &&
            defaults.integer(forKey: Self.keyCitrixNewlineDelayMs) == legacyNewlineDelayMs {
            defaults.set(preset.newlineDelayMs, forKey: Self.keyCitrixNewlineDelayMs)
        }

        let storedWordPauseMinMs: Int
        if defaults.object(forKey: Self.keyCitrixWordPauseMinMs) != nil {
            storedWordPauseMinMs = defaults.integer(forKey: Self.keyCitrixWordPauseMinMs)
        } else {
            storedWordPauseMinMs = 500
        }

        let storedWordPauseMaxMs: Int
        if defaults.object(forKey: Self.keyCitrixWordPauseMaxMs) != nil {
            storedWordPauseMaxMs = defaults.integer(forKey: Self.keyCitrixWordPauseMaxMs)
        } else {
            storedWordPauseMaxMs = 1_000
        }

        if storedWordPauseMinMs == 500 && storedWordPauseMaxMs == 1_000 {
            defaults.set(preset.wordPauseMinMs, forKey: Self.keyCitrixWordPauseMinMs)
            defaults.set(preset.wordPauseMaxMs, forKey: Self.keyCitrixWordPauseMaxMs)
        }
    }

    private func mapCitrixPreset(rawValue: String) -> CitrixTypingSpeedPreset? {
        if let preset = CitrixTypingSpeedPreset(rawValue: rawValue) {
            return preset
        }

        switch rawValue {
        case "cpm50", "safe": return .wpm50
        case "cpm80", "balanced", "wpm150": return .wpm80
        case "cpm150", "fast", "wpm680": return .wpm120
        default: return nil
        }
    }

    // MARK: - Transient Validation States

    var isDeepgramKeyValid = false
    var deepgramKeyError = ""

    var isOpenRouterKeyValid = false
    var openRouterKeyCredits = ""
    var openRouterKeyError = ""
}
