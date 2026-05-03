import SwiftUI
import KeyboardShortcuts

@main
struct VoicePolishApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("VoicePolish", systemImage: "mic.fill") {
            SettingsView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class AppState {
    let audioRecorder = AudioRecorder()
    let deepgramService = DeepgramService()
    let openRouterService = OpenRouterService()
    let textInsertionService = TextInsertionService()
    var settings = AppSettings.shared
    let logger = LoggingService.shared
    let permissionManager = PermissionManager()
    let historyService = HistoryService.shared
    let errorService = ErrorService.shared

    var customModelInput = ""

    /// Set to `true` by the hotkey handler to tell the popup view to trigger stopAndSend.
    var shouldStopAndSend = false

    private var configChangeObserver: NSObjectProtocol?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.toggleRecordingPopup()
        }
        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            self?.cancelRecordingFromHotkey()
        }
        permissionManager.checkAndRequestPermissions()
        logger.info("VoicePolish started")

        // Monitor for audio engine configuration changes and recover proactively
        registerConfigChangeObserver()

        // Warm up audio engine asynchronously so first recording is instant.
        // The engine stays running (discarding buffers) until a recording starts.
        Task { @MainActor [weak self] in
            do {
                try await self?.audioRecorder.warmUp()
                self?.logger.info("Initial audio engine warmup successful")
            } catch {
                self?.logger.error("Audio engine warm-up failed: \(error)")
                // Transient: app will retry warmup on next hotkey press anyway, so
                // surface as observability-only — no need to scare the user.
                ErrorService.shared.addError(
                    source: .audioRecorder, severity: .warning,
                    message: "Initial audio engine warmup failed",
                    details: error.localizedDescription,
                    actionable: false, transient: true,
                    code: "audio.warmup_initial_failed"
                )
            }
        }
    }

    private func registerConfigChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let engineState = self.audioRecorder.engineState.withLock { $0 }
            // Only recover if engine is broken or running (proactive maintenance)
            if case .broken = engineState {
                self.logger.info("Audio engine configuration changed and engine is broken, recovering...")
                Task { @MainActor in
                    do {
                        try await self.audioRecorder.recoverEngine()
                        self.logger.info("Proactive engine recovery after config change successful")
                    } catch {
                        self.logger.error("Proactive engine recovery failed: \(error)")
                        self.errorService.addError(source: .audioRecorder, severity: .error, message: "Proactive engine recovery failed", details: error.localizedDescription)
                    }
                }
            }
        }
    }

    nonisolated deinit {
        // Notification observers are automatically cleaned up by NotificationCenter
        // when the observer object is deallocated, so no explicit cleanup needed
    }

    func cancelRecordingFromHotkey() {
        let controller = RecordingPopupController.shared
        guard controller.isShowing,
              audioRecorder.state == .recording || audioRecorder.state == .paused else {
            return
        }
        logger.info("Cancel hotkey pressed — cancelling recording")
        audioRecorder.cancelRecording()
        controller.closePopup(appState: self)
    }

    func toggleRecordingPopup() {
        let controller = RecordingPopupController.shared
        if controller.isShowing {
            // If currently recording or paused, trigger stop & send via the flag
            if audioRecorder.state == .recording || audioRecorder.state == .paused {
                logger.info("Hotkey pressed while recording — triggering stopAndSend")
                shouldStopAndSend = true
            } else {
                // Not recording (idle, transcribing, etc.) — just close
                controller.closePopup(appState: self)
            }
        } else {
            // Check required settings
            guard !settings.deepgramAPIKey.isEmpty else {
                logger.error("Deepgram API key not configured")
                errorService.addError(
                    source: .general, severity: .error,
                    message: "Deepgram API key not configured",
                    details: "Open Settings and paste your Deepgram API key.",
                    code: "settings.deepgram_key_missing"
                )
                return
            }
            if settings.sendToLLMEnabled {
                guard !settings.openRouterAPIKey.isEmpty else {
                    logger.error("OpenRouter API key not configured")
                    errorService.addError(
                        source: .general, severity: .error,
                        message: "OpenRouter API key not configured",
                        details: "Open Settings and paste your OpenRouter API key, or disable Send to LLM.",
                        code: "settings.openrouter_key_missing"
                    )
                    return
                }
            }

            permissionManager.checkMicrophonePermission()

            // Start recording BEFORE showing popup to eliminate SwiftUI rendering delay.
            // Audio capture begins the instant the hotkey is pressed.
            do {
                try audioRecorder.startRecording()
            } catch AudioRecorder.RecorderError.engineBroken(let reason) {
                // Engine is broken — show popup and attempt recovery via the backoff ladder.
                //
                // v0.3.12 severity re-classification: this is now .warning, not .critical.
                // With the backoff ladder in AudioRecorder.recoverEngine(), the ladder
                // almost always recovers within 8.75s. CRITICAL is reserved for
                // "user is blocked and must take action", which this event no longer is.
                // The catch block below (Engine recovery failed) is where the error
                // becomes genuinely user-facing — that stays at .error severity because
                // the ladder exhausted.
                logger.info("Engine is broken (\(reason)), attempting recovery via backoff ladder")
                errorService.addError(source: .audioRecorder, severity: .warning, message: "Audio engine broken", details: reason)
                controller.showPopup(appState: self)
                Task { @MainActor in
                    do {
                        try await audioRecorder.recoverEngine()
                        try audioRecorder.startRecording()
                        logger.info("Recovery and recording started successfully")
                    } catch {
                        logger.error("Failed to recover engine or start recording: \(error)")
                        errorService.addError(source: .audioRecorder, severity: .error, message: "Engine recovery failed", details: error.localizedDescription)
                        controller.closePopup(appState: self)
                    }
                }
                return
            } catch AudioRecorder.RecorderError.engineNotReady {
                // Engine not ready (warming up) — show popup and wait for warmup
                logger.info("Engine not ready, warming up before recording")
                controller.showPopup(appState: self)
                Task { @MainActor in
                    do {
                        try await audioRecorder.warmUp()
                        try audioRecorder.startRecording()
                        logger.info("Warmup complete, recording started")
                    } catch {
                        logger.error("Failed to start recording after warmup: \(error)")
                        errorService.addError(source: .audioRecorder, severity: .error, message: "Failed to start recording after warmup", details: error.localizedDescription)
                        controller.closePopup(appState: self)
                    }
                }
                return
            } catch {
                logger.error("Failed to start recording: \(error)")
                errorService.addError(source: .audioRecorder, severity: .error, message: "Failed to start recording", details: error.localizedDescription)
                return
            }

            controller.showPopup(appState: self)
        }
    }
}
