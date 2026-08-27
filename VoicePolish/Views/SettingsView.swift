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

struct CustomVocabularyView: View {
    @Bindable var appState: AppState

    @State private var enabled = false
    @State private var keyterms: [String] = []
    @State private var newKeyterm = ""

    private var usesKeyterm: Bool {
        appState.settings.deepgramModel.hasPrefix("nova-3")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Custom Vocabulary", isOn: $enabled)
                .font(.subheadline.bold())
                .onChange(of: enabled) { _, newValue in
                    appState.settings.deepgramVocabularyEnabled = newValue
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(usesKeyterm ? "Keyterms (boost recognition)" : "Keywords (boost recognition)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                HStack {
                    TextField("e.g. Tavily, MCP...", text: $newKeyterm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addKeyterm() }
                    Button("Add") { addKeyterm() }
                        .disabled(newKeyterm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !keyterms.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(keyterms, id: \.self) { term in
                            HStack {
                                Text(term)
                                    .font(.caption)
                                Spacer()
                                Button {
                                    removeKeyterm(term)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(4)
                        }
                    }
                }

                Text(usesKeyterm ? "Up to ~50 terms. Using keyterm (Nova-3)" : "Up to 100 terms. Using keywords (\(appState.settings.deepgramModel))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .onAppear {
            enabled = appState.settings.deepgramVocabularyEnabled
            keyterms = appState.settings.deepgramKeyterms
        }
    }

    private func addKeyterm() {
        let term = newKeyterm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !keyterms.contains(term) else { return }
        keyterms.append(term)
        appState.settings.deepgramKeyterms = keyterms
        newKeyterm = ""
    }

    private func removeKeyterm(_ term: String) {
        keyterms.removeAll { $0 == term }
        appState.settings.deepgramKeyterms = keyterms
    }
}

struct CitrixTypingPresetPickerView: View {
    @Bindable var appState: AppState

    @State private var selectedPreset: AppSettings.CitrixTypingSpeedPreset = .wpm50
    @State private var effectiveTimings = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop & Type Speed")
                .font(.subheadline.bold())

            Picker("", selection: $selectedPreset) {
                ForEach(AppSettings.CitrixTypingSpeedPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .labelsHidden()
            .onChange(of: selectedPreset) { _, newValue in
                appState.settings.citrixTypingSpeedPreset = newValue
                refreshEffectiveTimings()
            }

            Text(selectedPreset.detailText)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(effectiveTimings)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            selectedPreset = appState.settings.citrixTypingSpeedPreset
            refreshEffectiveTimings()
        }
    }

    private func refreshEffectiveTimings() {
        let settings = appState.settings
        effectiveTimings =
            "Current timings: key \(settings.citrixTypingInterKeyDelayMs)ms • newline \(settings.citrixTypingNewlineDelayMs)ms • chunk \(settings.citrixTypingChunkSize) • pause \(settings.citrixTypingChunkPauseMs)ms • word pause \(settings.citrixTypingWordPauseMinMs)-\(settings.citrixTypingWordPauseMaxMs)ms • jitter ±\(settings.citrixTypingCharJitterMs)ms"
    }
}

struct StopAndTypeMethodView: View {
    @Bindable var appState: AppState

    // @Observable does not track UserDefaults-backed computed properties, so
    // mirror into @State and write back on change (see AppSettings.swift:83-85).
    @State private var selectedMethod: AppSettings.TypingMethod = .automatic
    @State private var asciiFoldEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop & Type Method")
                .font(.subheadline.bold())

            Picker("", selection: $selectedMethod) {
                ForEach(AppSettings.TypingMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .labelsHidden()
            .onChange(of: selectedMethod) { _, newValue in
                appState.settings.typingMethod = newValue
            }

            Text(selectedMethod.detailText)
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Simplify punctuation before typing", isOn: $asciiFoldEnabled)
                .font(.caption)
                .padding(.top, 4)
                .onChange(of: asciiFoldEnabled) { _, newValue in
                    appState.settings.typingAsciiFoldEnabled = newValue
                }

            Text("Converts curly quotes, em dashes and ellipses to plain ASCII. On a US layout those all need the Option key, which remote desktops receive as Alt — a menu shortcut rather than a character.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            selectedMethod = appState.settings.typingMethod
            asciiFoldEnabled = appState.settings.typingAsciiFoldEnabled
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var temperatureValue: Double = 0.3
    @State private var selectedTab: SettingsTab = .settings
    @State private var sendToLLMEnabled: Bool = true

    // Recordings Archive (v0.3.30) — mirrored from settings in onAppear because
    // @Observable does not track UserDefaults-backed computed properties.
    @State private var audioArchivalEnabled: Bool = true
    @State private var archiveSuccessfulRecordings: Bool = true
    @State private var retentionIndex: Int = 0

    private let retentionChoices: [(label: String, policy: AudioRetentionPolicy)] = [
        ("7 days", .maxAgeDays(7)),
        ("30 days", .maxAgeDays(30)),
        ("Last 50 recordings", .lastN(50)),
        ("Last 200 recordings", .lastN(200)),
        ("Keep all", .keepAll),
    ]

    private enum SettingsTab {
        case settings
        case history
        case errors
    }

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
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                tabButton("Settings", systemImage: "gear", tab: .settings)
                tabButton("History", systemImage: "clock.arrow.circlepath", tab: .history)
                tabButton("Errors", systemImage: "exclamationmark.triangle", tab: .errors)
                    .overlay(alignment: .topTrailing) {
                        if ErrorService.shared.hasRecentErrors {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                                .offset(x: -8, y: 4)
                        }
                    }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Tab content
            switch selectedTab {
            case .settings:
                settingsContent
            case .history:
                HistoryView(appState: appState)
            case .errors:
                ErrorsView()
            }
        }
        .frame(width: 520, height: 620)
        .onAppear {
            temperatureValue = appState.settings.temperature
            sendToLLMEnabled = appState.settings.sendToLLMEnabled
            audioArchivalEnabled = appState.settings.audioArchivalEnabled
            archiveSuccessfulRecordings = appState.settings.archiveSuccessfulRecordings
            retentionIndex = retentionChoices.firstIndex { $0.policy == appState.settings.audioRetentionPolicy } ?? 0
        }
    }

    private func tabButton(_ title: String, systemImage: String, tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private var settingsContent: some View {
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
                HStack {
                    Text("Stop & Type Hotkey:")
                        .font(.subheadline.bold())
                    KeyboardShortcuts.Recorder("", name: .stopAndType)
                }
                Text("Stops recording and types the result key by key, like a real keyboard — for Windows App / RDP, Citrix and other remote desktops where paste is blocked. Does nothing if no recording is in progress.")
                    .font(.caption)
                    .foregroundColor(.secondary)

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

                // MARK: - Custom Vocabulary
                CustomVocabularyView(appState: appState)

                Divider()

                // MARK: - Send to LLM Toggle
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Send to LLM", isOn: $sendToLLMEnabled)
                        .font(.subheadline.bold())
                        .onChange(of: sendToLLMEnabled) { _, newValue in
                            appState.settings.sendToLLMEnabled = newValue
                        }
                    Text("When disabled, raw transcript is pasted directly without LLM processing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: - OpenRouter API Key
                Group {
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
                }
                .disabled(!sendToLLMEnabled)
                .opacity(sendToLLMEnabled ? 1 : 0.5)

                Divider()

                // MARK: - Stop & Type
                StopAndTypeMethodView(appState: appState)

                CitrixTypingPresetPickerView(appState: appState)

                Divider()

                // MARK: - Recordings Archive
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recordings Archive")
                        .font(.subheadline.bold())

                    Toggle("Save recording audio (enables Retry on failed transcriptions)",
                           isOn: $audioArchivalEnabled)
                        .onChange(of: audioArchivalEnabled) { _, v in
                            appState.settings.audioArchivalEnabled = v
                        }

                    Group {
                        Picker("Save audio for", selection: $archiveSuccessfulRecordings) {
                            Text("All recordings").tag(true)
                            Text("Failed only").tag(false)
                        }
                        .onChange(of: archiveSuccessfulRecordings) { _, v in
                            appState.settings.archiveSuccessfulRecordings = v
                        }

                        Picker("Keep audio", selection: $retentionIndex) {
                            ForEach(retentionChoices.indices, id: \.self) { i in
                                Text(retentionChoices[i].label).tag(i)
                            }
                        }
                        .onChange(of: retentionIndex) { _, i in
                            appState.settings.audioRetentionPolicy = retentionChoices[i].policy
                        }

                        Text("Audio is stored locally in Application Support and pruned automatically. History text is always kept.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .disabled(!audioArchivalEnabled)
                    .opacity(audioArchivalEnabled ? 1 : 0.5)
                }

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
                        Image(systemName: "mic.fill")
                            .foregroundColor(.blue)
                        Text("Input: \(appState.audioRecorder.currentInputDeviceName)")
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
    }
}
