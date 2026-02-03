import SwiftUI
import KeyboardShortcuts

// MARK: - LLM Model Picker

/// Separate view with its own @State so the Picker binding always maps to a valid tag.
struct LLMModelPickerView: View {
    @Bindable var appState: AppState

    /// Picker selection: either a known model ID or "__custom__".
    @State private var pickerSelection: String = ""
    @State private var customModelText: String = ""
    /// Local display of the active model (avoids @Observable/UserDefaults reactivity gap).
    @State private var displayedModel: String = ""
    /// Verification state for custom models.
    @State private var isVerifying = false
    @State private var verificationError: String?

    private var isCustom: Bool {
        pickerSelection == "__custom__" || !LLMModel.popularModels.contains(where: { $0.id == pickerSelection })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LLM Model")
                .font(.subheadline.bold())

            Picker("", selection: $pickerSelection) {
                ForEach(LLMModel.popularModels) { model in
                    Text(model.displayName).tag(model.id)
                }
                Text("Custom...").tag("__custom__")
            }
            .labelsHidden()
            .onChange(of: pickerSelection) { _, newValue in
                if newValue != "__custom__" {
                    appState.settings.selectedModel = newValue
                    displayedModel = newValue
                    verificationError = nil
                }
            }

            if isCustom {
                TextField("Model ID (e.g. anthropic/claude-sonnet-4)", text: $customModelText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        verifyAndApply()
                    }

                HStack(spacing: 8) {
                    Button("Verify & Apply") {
                        verifyAndApply()
                    }
                    .disabled(customModelText.isEmpty || isVerifying)

                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = verificationError {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 4) {
                Text("Current: \(displayedModel)")
                if !isCustom || displayedModel == customModelText {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .onAppear {
            let current = appState.settings.selectedModel
            displayedModel = current
            if LLMModel.popularModels.contains(where: { $0.id == current }) {
                pickerSelection = current
            } else {
                pickerSelection = "__custom__"
                customModelText = current
            }
        }
    }

    private func verifyAndApply() {
        guard !customModelText.isEmpty else { return }
        let modelId = customModelText
        let apiKey = appState.settings.openRouterAPIKey

        guard !apiKey.isEmpty else {
            verificationError = "OpenRouter API key not configured"
            return
        }

        isVerifying = true
        verificationError = nil

        Task {
            let error = await appState.openRouterService.verifyModel(modelId: modelId, apiKey: apiKey)
            isVerifying = false
            if let error {
                verificationError = error
            } else {
                verificationError = nil
                appState.settings.selectedModel = modelId
                displayedModel = modelId
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var temperatureValue: Double = 0.3

    private var temperatureDescription: String {
        switch temperatureValue {
        case 0.0...0.3:
            return "Deterministic (consistent, focused output) — Recommended for cleanup tasks"
        case 0.3...0.7:
            return "Balanced (consistent with minor variation)"
        case 0.7...1.0:
            return "Creative (more varied output)"
        case 1.0...2.0:
            return "Very Creative (⚠️ May be slow with reasoning models, increases processing time)"
        default:
            return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("VoicePolish Settings")
                    .font(.title2.bold())

                Divider()

                // MARK: - Hotkey
                HStack {
                    Text("Recording Hotkey:")
                        .font(.subheadline.bold())
                    KeyboardShortcuts.Recorder("", name: .toggleRecording)
                }
                HStack {
                    Text("Cancel Hotkey:")
                        .font(.subheadline.bold())
                    KeyboardShortcuts.Recorder("", name: .cancelRecording)
                }

                Divider()

                // MARK: - Deepgram API Key
                APIKeyView(
                    title: "Deepgram API Key",
                    placeholder: "Enter Deepgram API key...",
                    apiKey: $appState.settings.deepgramAPIKey,
                    isValid: appState.settings.isDeepgramKeyValid,
                    errorMessage: appState.settings.deepgramKeyError,
                    onVerify: {
                        await appState.deepgramService.verifyAPIKey(appState.settings)
                    }
                )

                // MARK: - Deepgram Model
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deepgram STT Model")
                        .font(.subheadline.bold())
                    Picker("", selection: $appState.settings.deepgramModel) {
                        ForEach(DeepgramModel.availableModels) { model in
                            Text("\(model.displayName) (\(model.pricePerMin)/min)")
                                .tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                Divider()

                // MARK: - OpenRouter API Key
                APIKeyView(
                    title: "OpenRouter API Key",
                    placeholder: "sk-or-v1-...",
                    apiKey: $appState.settings.openRouterAPIKey,
                    isValid: appState.settings.isOpenRouterKeyValid,
                    errorMessage: appState.settings.openRouterKeyError,
                    credits: appState.settings.openRouterKeyCredits.isEmpty ? nil : appState.settings.openRouterKeyCredits,
                    onVerify: {
                        await appState.openRouterService.verifyAPIKey(appState.settings)
                    }
                )

                // MARK: - LLM Model
                LLMModelPickerView(appState: appState)

                // MARK: - Temperature
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                            .font(.subheadline.bold())
                        Spacer()
                        Text(String(format: "%.2f", temperatureValue))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $temperatureValue, in: 0.0...2.0, step: 0.1)
                        .onChange(of: temperatureValue) { _, newValue in
                            appState.settings.temperature = newValue
                        }

                    Text(temperatureDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // MARK: - System Prompt
                SystemPromptView(systemPrompt: $appState.settings.systemPrompt)

                Divider()

                // MARK: - Permissions
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permissions")
                        .font(.subheadline.bold())

                    HStack {
                        Image(systemName: appState.permissionManager.microphoneGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(appState.permissionManager.microphoneGranted ? .green : .red)
                        Text("Microphone")
                    }

                    HStack {
                        Image(systemName: appState.permissionManager.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(appState.permissionManager.accessibilityGranted ? .green : .red)
                        Text("Accessibility")

                        if !appState.permissionManager.accessibilityGranted {
                            Button("Grant Access") {
                                appState.permissionManager.requestAccessibilityPermission()
                            }
                            .font(.caption)
                        }
                    }

                    HStack {
                        Button("Refresh") {
                            appState.permissionManager.checkAndRequestPermissions()
                        }
                        Button("Open Settings") {
                            appState.permissionManager.openAccessibilitySettings()
                        }
                    }
                }
                .font(.caption)

                Divider()

                Button("Quit VoicePolish") {
                    NSApplication.shared.terminate(nil)
                }

                HStack {
                    Spacer()
                    Text("v\(appVersion)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding()
        }
        .frame(width: 420, height: 600)
        .onAppear {
            temperatureValue = appState.settings.temperature
        }
    }
}
