import Foundation
import SwiftUI

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Note: @Observable does not properly track changes to computed properties backed by UserDefaults.
    /// Views that need reactive updates should use local @State variables that explicitly read from
    /// these properties, rather than relying on automatic observation. See LLMModelPickerView for example.

    /// Old default prompt — used to detect and auto-migrate to the new one.
    private static let oldDefaultPrompt = "Rewrite the text we received from audio, by considering the grammar of the language"

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

    // MARK: - Transient Validation States

    var isDeepgramKeyValid = false
    var deepgramKeyError = ""

    var isOpenRouterKeyValid = false
    var openRouterKeyCredits = ""
    var openRouterKeyError = ""
}
