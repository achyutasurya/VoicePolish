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
        permissionManager.checkAndRequestPermissions()
        logger.info("VoicePolish started")
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
            controller.showPopup(appState: self)
        }
    }
}
