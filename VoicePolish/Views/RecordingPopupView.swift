import SwiftUI
import AppKit

// MARK: - NSPanel Controller

@MainActor
final class RecordingPopupController {
    static let shared = RecordingPopupController()

    private var panel: NSPanel?
    /// The app that was frontmost when the popup opened — we re-activate it before pasting.
    var previousApp: NSRunningApplication?

    var isShowing: Bool { panel != nil }

    func showPopup(appState: AppState) {
        if panel != nil { return }

        // Remember the currently focused app so we can re-activate it before pasting
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.title = "VoicePolish"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        // Restore saved position or center
        let settings = appState.settings
        if settings.popupX != 0 || settings.popupY != 0 {
            panel.setFrameOrigin(NSPoint(x: settings.popupX, y: settings.popupY))
        } else {
            panel.center()
        }

        let hostingView = NSHostingView(
            rootView: RecordingPopupView(appState: appState) { [weak self] in
                self?.closePopup(appState: appState)
            }
        )
        panel.contentView = hostingView
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func closePopup(appState: AppState) {
        guard let panel else { return }
        let frame = panel.frame
        appState.settings.popupX = frame.origin.x
        appState.settings.popupY = frame.origin.y

        panel.close()
        self.panel = nil
    }
}

// MARK: - SwiftUI View

struct RecordingPopupView: View {
    @Bindable var appState: AppState
    let onClose: () -> Void

    /// Recording is already in progress when the popup appears (started in toggleRecordingPopup).
    @State private var popupState: PopupState = .recording

    enum PopupState: Equatable {
        case idle
        case recording
        case paused
        case transcribing
        case processing
        case done
        case error(String)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Status display
            statusView

            // Controls
            controlsView
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: appState.shouldStopAndSend) { _, newValue in
            if newValue {
                appState.shouldStopAndSend = false
                Task { await stopAndSend() }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch popupState {
        case .idle:
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Starting...")
                    .font(.headline)
            }

        case .recording:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text("Recording")
                        .font(.headline)
                        .foregroundColor(.red)
                }
                Text(formattedDuration)
                    .font(.title.monospacedDigit())

                // Audio level bar
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.green.gradient)
                        .frame(width: geometry.size.width * CGFloat(appState.audioRecorder.audioLevel))
                }
                .frame(height: 6)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }

        case .paused:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.fill")
                        .foregroundColor(.yellow)
                    Text("Paused")
                        .font(.headline)
                }
                Text(formattedDuration)
                    .font(.title.monospacedDigit())
            }

        case .transcribing:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("Transcribing audio...")
                    .font(.headline)
            }

        case .processing:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("Processing with LLM...")
                    .font(.headline)
            }

        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                Text("Done!")
                    .font(.headline)
            }

        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var controlsView: some View {
        HStack(spacing: 12) {
            switch popupState {
            case .idle:
                // Auto-starting, but show cancel in case it fails
                Button(action: onClose) {
                    Label("Cancel", systemImage: "xmark")
                }

            case .recording:
                Button(action: cancelRecording) {
                    Label("Cancel", systemImage: "xmark")
                }
                .tint(.red)

                Button(action: { Task { await stopAndSend() } }) {
                    Label("Stop & Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

            case .paused:
                Button(action: resumeRecording) {
                    Label("Resume", systemImage: "mic.fill")
                }
                .tint(.green)

                Button(action: cancelRecording) {
                    Label("Cancel", systemImage: "xmark")
                }
                .tint(.red)

                Button(action: { Task { await stopAndSend() } }) {
                    Label("Stop & Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

            case .transcribing, .processing:
                EmptyView()

            case .done:
                EmptyView()

            case .error:
                Button("Retry") {
                    startRecording()
                }

                Button("Close") {
                    onClose()
                }
            }
        }
    }

    private var formattedDuration: String {
        let duration = appState.audioRecorder.recordingDuration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration - Double(Int(duration))) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    // MARK: - Actions

    private func startRecording() {
        do {
            try appState.audioRecorder.startRecording()
            popupState = .recording
        } catch {
            popupState = .error(error.localizedDescription)
        }
    }

    private func pauseRecording() {
        appState.audioRecorder.pauseRecording()
        popupState = .paused
    }

    private func resumeRecording() {
        do {
            try appState.audioRecorder.resumeRecording()
            popupState = .recording
        } catch {
            popupState = .error(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        appState.audioRecorder.cancelRecording()
        onClose()
    }

    private func stopAndSend() async {
        let logger = appState.logger

        // 1. Stop recording
        logger.info("stopAndSend: stopping recording...")
        popupState = .transcribing
        _ = appState.audioRecorder.stopRecording()

        // 2. Get audio data
        guard let wavData = appState.audioRecorder.getAudioData() else {
            logger.error("stopAndSend: no audio data")
            popupState = .error("No audio data recorded")
            return
        }
        logger.info("stopAndSend: got \(wavData.count) bytes of audio")

        // 3. Transcribe with Deepgram
        let transcript: String
        do {
            logger.info("stopAndSend: sending to Deepgram...")
            transcript = try await appState.deepgramService.transcribeAudio(
                wavData: wavData,
                apiKey: appState.settings.deepgramAPIKey,
                model: appState.settings.deepgramModel
            )
            logger.info("stopAndSend: transcript received (\(transcript.count) chars): \(transcript)")
        } catch {
            logger.error("stopAndSend: transcription failed - \(error)")
            popupState = .error("Transcription failed: \(error.localizedDescription)")
            return
        }

        // 4. Process with LLM
        popupState = .processing
        let responseText: String
        do {
            logger.info("stopAndSend: sending to OpenRouter model \(appState.settings.selectedModel) (temperature: \(appState.settings.temperature))...")
            responseText = try await appState.openRouterService.processText(
                transcript: transcript,
                systemPrompt: appState.settings.systemPrompt,
                model: appState.settings.selectedModel,
                apiKey: appState.settings.openRouterAPIKey,
                temperature: appState.settings.temperature
            )
            logger.info("stopAndSend: LLM response received (\(responseText.count) chars): \(responseText)")
        } catch {
            logger.error("stopAndSend: LLM failed - \(error)")
            popupState = .error("LLM processing failed: \(error.localizedDescription)")
            return
        }

        // 5. Determine the target app for pasting.
        //    Use the app that was frontmost when we opened the popup.
        //    But also check current frontmost as a fallback — the user may have
        //    switched apps while recording (in that case, we still try previousApp).
        let targetApp = RecordingPopupController.shared.previousApp
        let currentFront = NSWorkspace.shared.frontmostApplication
        logger.info("stopAndSend: target app (from popup open): \(targetApp?.localizedName ?? "nil") (pid: \(targetApp?.processIdentifier ?? 0))")
        logger.info("stopAndSend: current frontmost: \(currentFront?.localizedName ?? "nil") (pid: \(currentFront?.processIdentifier ?? 0))")

        // 6. Close popup
        logger.info("stopAndSend: closing popup...")
        onClose()

        // Deactivate VoicePolish so it gives up being the active app
        NSApp.deactivate()

        // Re-activate the target app
        if let targetApp {
            logger.info("stopAndSend: activating \(targetApp.localizedName ?? "unknown") (pid: \(targetApp.processIdentifier))...")
            targetApp.activate()
        }

        // Wait for focus transfer — 500ms to be safe
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Log which app is now frontmost after activation
        let frontApp = NSWorkspace.shared.frontmostApplication
        logger.info("stopAndSend: frontmost app after activation: \(frontApp?.localizedName ?? "nil") (pid: \(frontApp?.processIdentifier ?? 0))")

        // Verify the correct app got focus
        if let targetApp, frontApp?.processIdentifier != targetApp.processIdentifier {
            logger.error("stopAndSend: WARNING - focus went to \(frontApp?.localizedName ?? "nil") instead of \(targetApp.localizedName ?? "nil"). Retrying activation...")
            targetApp.activate()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let retryFront = NSWorkspace.shared.frontmostApplication
            logger.info("stopAndSend: after retry, frontmost is: \(retryFront?.localizedName ?? "nil") (pid: \(retryFront?.processIdentifier ?? 0))")
        }

        // 7. Insert text via clipboard + Cmd+V
        do {
            logger.info("stopAndSend: inserting text (\(responseText.count) chars)...")
            try await appState.textInsertionService.insertText(responseText)
            logger.info("stopAndSend: text inserted successfully!")
        } catch {
            logger.error("stopAndSend: text insertion failed - \(error)")
            return
        }

        logger.info("stopAndSend: complete!")
    }
}
