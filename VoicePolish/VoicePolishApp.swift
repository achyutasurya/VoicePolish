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

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.toggleRecordingPopup()
        }
        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            self?.cancelRecordingFromHotkey()
        }
        permissionManager.checkAndRequestPermissions()
        logger.info("VoicePolish started")

        // Warm up audio engine so first recording is instant.
        // The engine stays running (discarding buffers) until a recording starts.
        do {
            try audioRecorder.warmUp()
        } catch {
            logger.error("Audio engine warm-up failed: \(error)")
        }
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
            } catch {
                logger.error("Failed to start recording: \(error)")
                return
            }

            controller.showPopup(appState: self)
        }
    }
}
