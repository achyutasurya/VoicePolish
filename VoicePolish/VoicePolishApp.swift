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
                return
            }
            guard !settings.openRouterAPIKey.isEmpty else {
                logger.error("OpenRouter API key not configured")
                return
            }

            permissionManager.checkMicrophonePermission()

            // Start recording BEFORE showing popup to eliminate SwiftUI rendering delay.
            // Audio capture begins the instant the hotkey is pressed.
            do {
                try audioRecorder.startRecording()
            } catch AudioRecorder.RecorderError.engineBroken(let reason) {
                // Engine is broken — show popup and attempt recovery
                logger.error("Engine is broken (\(reason)), attempting recovery")
                controller.showPopup(appState: self)
                Task { @MainActor in
                    do {
                        try await audioRecorder.recoverEngine()
                        try audioRecorder.startRecording()
                        logger.info("Recovery and recording started successfully")
                    } catch {
                        logger.error("Failed to recover engine or start recording: \(error)")
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
                        controller.closePopup(appState: self)
                    }
                }
                return
            } catch {
                logger.error("Failed to start recording: \(error)")
                return
            }

            controller.showPopup(appState: self)
        }
    }
}
