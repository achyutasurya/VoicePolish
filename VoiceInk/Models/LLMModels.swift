import Foundation

struct LLMModel: Identifiable, Hashable {
    let id: String
    let displayName: String

    static let popularModels: [LLMModel] = [
        LLMModel(id: "deepseek/deepseek-chat", displayName: "DeepSeek Chat (Recommended)"),
        LLMModel(id: "anthropic/claude-3-haiku", displayName: "Claude 3 Haiku"),
        LLMModel(id: "anthropic/claude-sonnet-4", displayName: "Claude Sonnet 4"),
        LLMModel(id: "openai/gpt-4o", displayName: "GPT-4o"),
        LLMModel(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
        LLMModel(id: "meta-llama/llama-3.3-70b-instruct", displayName: "Llama 3.3 70B"),
    ]

    static let defaultModel = popularModels[0]
}

struct DeepgramModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let pricePerMin: String

    static let availableModels: [DeepgramModel] = [
        DeepgramModel(id: "nova-3", displayName: "Nova-3 Monolingual", pricePerMin: "$0.0077"),
        DeepgramModel(id: "nova-3-general", displayName: "Nova-3 Multilingual", pricePerMin: "$0.0092"),
        DeepgramModel(id: "nova-2", displayName: "Nova-2", pricePerMin: "$0.0058"),
        DeepgramModel(id: "enhanced", displayName: "Enhanced", pricePerMin: "$0.0165"),
        DeepgramModel(id: "base", displayName: "Base", pricePerMin: "$0.0145"),
        DeepgramModel(id: "nova-3-flux", displayName: "Flux", pricePerMin: "$0.0077"),
    ]

    static let defaultModel = availableModels[0]
}
