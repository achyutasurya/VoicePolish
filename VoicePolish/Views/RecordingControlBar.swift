import SwiftUI
import AppKit

/// Record / Stop & Paste / Stop & Type / Discard at the top of the menubar window,
/// so the pipeline can be driven without hotkeys. Every button calls the same
/// `AppState` entry point as its hotkey, so the two paths cannot drift apart.
struct RecordingControlBar: View {
    @Bindable var appState: AppState

    /// The MenuBarExtra window hosting this bar — closed before acting so the
    /// popover never sits over the target text field.
    @State private var hostWindow: NSWindow?
    @State private var preflightMessage: String?
    /// Tooltip text per action. Refreshed on appear: shortcut storage is
    /// UserDefaults-backed and not observable.
    @State private var shortcutHints: [HotkeyAction: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                controlButton("Record", systemImage: "record.circle", action: .record,
                              enabled: state == .idle, tint: .red, perform: record)
                controlButton("Stop & Paste", systemImage: "stop.circle", action: .record,
                              enabled: state == .recording, perform: stopAndPaste)
                controlButton("Stop & Type", systemImage: "keyboard", action: .stopAndType,
                              enabled: state == .recording, perform: stopAndType)
                controlButton("Discard", systemImage: "xmark.circle", action: .discard,
                              enabled: state != .idle, perform: discard)
            }

            HStack(spacing: 4) {
                if state == .recording {
                    Circle().fill(.red).frame(width: 6, height: 6)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            if let preflightMessage {
                Text(preflightMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(HostingWindowReader(window: $hostWindow))
        .onAppear {
            preflightMessage = nil
            shortcutHints = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.compactMap { action in
                action.shortcutsDescription.map { (action, $0) }
            })
        }
    }

    private var state: AppState.RecordingControlState { appState.controlState }

    private var statusText: String {
        switch state {
        case .idle:
            return "Ready"
        case .recording:
            let duration = appState.audioRecorder.recordingDuration
            let time = String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
            return appState.audioRecorder.state == .paused ? "Paused \(time)" : "Recording \(time)"
        case .busy:
            return "Working…"
        case .typing:
            // Keystrokes go to whatever app has focus, and opening this window focuses
            // VoicePolish — so say it plainly rather than let text land here silently.
            return "Typing… keystrokes now go to this window — Discard to stop"
        }
    }

    private func controlButton(_ title: String, systemImage: String, action: HotkeyAction,
                               enabled: Bool, tint: Color? = nil,
                               perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(tint)
        .disabled(!enabled)
        .help(shortcutHints[action].map { "\(title) (\($0))" } ?? title)
    }

    // MARK: - Actions

    private func record() {
        if let preflight = appState.startPreflightError() {
            preflightMessage = "\(preflight.message). \(preflight.details)"
            return
        }
        preflightMessage = nil
        dismissMenubarWindow()
        appState.startRecording()

        // The click activated VoicePolish; hand focus straight back so the user lands
        // in the field they were in while the recording runs.
        let controller = RecordingPopupController.shared
        returnFocus(to: controller.isShowing ? controller.previousApp : FrontmostAppTracker.shared.lastExternalApp)
    }

    private func stopAndPaste() {
        dismissMenubarWindow()
        // Focus hand-off to the target app happens in the popup's delivery path.
        appState.requestStopAndPaste()
    }

    private func stopAndType() {
        dismissMenubarWindow()
        appState.requestStopAndType()
    }

    private func discard() {
        // Capture before discard() closes the popup and the target goes out of reach.
        let controller = RecordingPopupController.shared
        let target = controller.isShowing ? controller.previousApp : FrontmostAppTracker.shared.lastExternalApp
        dismissMenubarWindow()
        appState.discard()
        returnFocus(to: target)
    }

    private func dismissMenubarWindow() {
        hostWindow?.close()
    }

    private func returnFocus(to app: NSRunningApplication?) {
        guard let app, !FrontmostAppTracker.isSelf(app) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}

/// Exposes the `NSWindow` hosting a SwiftUI view. MenuBarExtra has no dismiss API
/// that works on macOS 14, so closing the window directly is the reliable route.
private struct HostingWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}
