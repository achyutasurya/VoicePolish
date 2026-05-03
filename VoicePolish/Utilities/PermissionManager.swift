import AVFoundation
import ApplicationServices
import AppKit

@MainActor
@Observable
final class PermissionManager {
    var microphoneGranted = false
    var accessibilityGranted = false

    private let logger = LoggingService.shared

    func checkAndRequestPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        // v0.3.26: log permission status so silent-mic-due-to-denied-permission
        // is debuggable. Pre-v0.3.26 macOS would silently feed all-zero buffers
        // when permission was denied, producing peak=-100/mean=-100 stats with
        // no other diagnostic.
        switch status {
        case .authorized:
            microphoneGranted = true
            logger.info("Microphone permission: AUTHORIZED")
        case .notDetermined:
            logger.info("Microphone permission: NOT_DETERMINED — requesting via system prompt")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.microphoneGranted = granted
                    self?.logger.info("Microphone permission request result: \(granted ? "GRANTED" : "DENIED")")
                    if !granted {
                        ErrorService.shared.addError(
                            source: .audioRecorder, severity: .error,
                            message: "Microphone permission denied",
                            details: "VoicePolish needs microphone access to record. Open System Settings → Privacy & Security → Microphone and enable VoicePolish.",
                            code: "permission.microphone_denied"
                        )
                    }
                }
            }
        case .denied:
            microphoneGranted = false
            logger.error("Microphone permission: DENIED — recordings will be silent (all-zero buffers)")
            ErrorService.shared.addError(
                source: .audioRecorder, severity: .error,
                message: "Microphone permission denied",
                details: "VoicePolish needs microphone access to record. Open System Settings → Privacy & Security → Microphone and enable VoicePolish, then restart the app.",
                code: "permission.microphone_denied"
            )
        case .restricted:
            microphoneGranted = false
            logger.error("Microphone permission: RESTRICTED — managed by parental controls / MDM, recordings will be silent")
            ErrorService.shared.addError(
                source: .audioRecorder, severity: .error,
                message: "Microphone permission restricted",
                details: "Microphone access is restricted by parental controls or device management.",
                code: "permission.microphone_restricted"
            )
        @unknown default:
            microphoneGranted = false
            logger.error("Microphone permission: UNKNOWN status (\(status.rawValue))")
        }
    }

    func checkAccessibilityPermission() {
        // Check without prompting first
        accessibilityGranted = AXIsProcessTrusted()
        logger.info("Accessibility permission: \(accessibilityGranted ? "GRANTED" : "NOT_GRANTED")")
    }

    /// Prompt the user for accessibility permission (shows system dialog).
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings directly to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
