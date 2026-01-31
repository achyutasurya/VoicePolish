import AVFoundation
import ApplicationServices
import AppKit

@MainActor
@Observable
final class PermissionManager {
    var microphoneGranted = false
    var accessibilityGranted = false

    func checkAndRequestPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.microphoneGranted = granted
                }
            }
        case .denied, .restricted:
            microphoneGranted = false
        @unknown default:
            microphoneGranted = false
        }
    }

    func checkAccessibilityPermission() {
        // Check without prompting first
        accessibilityGranted = AXIsProcessTrusted()
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
