import SwiftUI
import AppKit

// MARK: - NSPanel Controller

@MainActor
final class RecordingPopupController {
    static let shared = RecordingPopupController()

    private var panel: NSPanel?
    /// The app that was frontmost when the popup opened — we re-activate it before pasting.
    /// Only set once per popup lifecycle to prevent race conditions.
    var previousApp: NSRunningApplication?

    var isShowing: Bool { panel != nil }

    func showPopup(appState: AppState) {
        // Guard against race: if popup is already showing, do not overwrite previousApp
        if panel != nil { return }

        // Remember the currently focused app so we can re-activate it before pasting.
        // This is set ONLY once when popup first opens to prevent race conditions
        // from rapid hotkey presses overwriting the target app.
        previousApp = NSWorkspace.shared.frontmostApplication

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
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

    /// P2 #5 Stage 3 (v0.3.22): live mic level indicator state.
    /// Set when `audioLevel` drops below 0.02 (≈-34 dBFS); fires `silentTooLong`
    /// after 1 s of continuous silence so the user gets immediate visual feedback
    /// that their mic is dead before they finish a recording with no audio.
    @State private var silentSinceTime: Date?
    @State private var silentTooLong: Bool = false
    @State private var silenceTimer: Timer?
    private let silenceLevelThreshold: Float = 0.02

    enum PopupState: Equatable {
        case idle
        case recording
        case paused
        case transcribing
        case processing
        case done
        case error(String)
        case engineBroken(String)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Status display
            statusView

            // Controls
            controlsView
        }
        .padding(20)
        .frame(width: 410)
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

                // Audio level bar — colour shifts to red if mic appears silent
                // for >1 s. Addresses the underlying root cause of "no speech
                // detected" errors: the user can't tell their mic is dead until
                // the empty transcript comes back. (v0.3.22, P2 #5 Stage 3.)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(silentTooLong ? Color.red.gradient : Color.green.gradient)
                        .frame(width: max(geometry.size.width * CGFloat(appState.audioRecorder.audioLevel), 2))
                }
                .frame(height: 6)
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .onChange(of: appState.audioRecorder.audioLevel) { _, newValue in
                    updateSilenceState(level: newValue)
                }

                if silentTooLong {
                    Text("Microphone appears silent — check input device")
                        .font(.caption)
                        .foregroundColor(.red)
                }
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

        case .engineBroken(let message):
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text("Audio Engine Recovery")
                    .font(.headline)
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text("Attempting automatic recovery...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
                    Label("Stop & Paste", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button(action: { Task { await stopAndCitrixSend() } }) {
                    Label("Stop & Type", systemImage: "keyboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

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
                    Label("Stop & Paste", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button(action: { Task { await stopAndCitrixSend() } }) {
                    Label("Stop & Type", systemImage: "keyboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

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

            case .engineBroken:
                Button("Cancel") {
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
        // Check if engine is broken
        let state = appState.audioRecorder.engineState.withLock { $0 }
        if case .broken = state {
            popupState = .engineBroken("Audio engine is in a broken state")
            Task {
                do {
                    try await appState.audioRecorder.recoverEngine()
                    try appState.audioRecorder.startRecording()
                    popupState = .recording
                } catch {
                    popupState = .error("Recovery failed: \(error.localizedDescription)")
                }
            }
            return
        }

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
        await stopAndDeliver(using: .normal)
    }

    private func stopAndCitrixSend() async {
        await stopAndDeliver(using: .citrixTyping)
    }

    private func stopAndDeliver(using mode: DeliveryMode) async {
        let logger = appState.logger
        let logPrefix = mode.logPrefix

        guard let responseText = await prepareFinalText(logPrefix: logPrefix) else {
            return
        }

        await focusTargetApp(logPrefix: logPrefix)

        do {
            switch mode {
            case .normal:
                logger.info("\(logPrefix): inserting text (\(responseText.count) chars) via clipboard paste...")
                try await appState.textInsertionService.insertText(responseText)
            case .citrixTyping:
                logger.info("\(logPrefix): inserting text (\(responseText.count) chars) via Citrix typing...")
                try await appState.textInsertionService.typeTextForCitrix(responseText)
            }
            logger.info("\(logPrefix): text insertion completed successfully")
        } catch {
            logger.error("\(logPrefix): text insertion failed - \(error)")
            appState.errorService.addError(source: .textInsertion, severity: .error, message: "Text insertion failed", details: error.localizedDescription)
        }
    }

    private func prepareFinalText(logPrefix: String) async -> String? {
        let logger = appState.logger
        let pipelineStart = CFAbsoluteTimeGetCurrent()

        // 1. Stop recording
        logger.info("\(logPrefix): stopping recording...")
        popupState = .transcribing
        _ = appState.audioRecorder.stopRecording()

        // 1a. Client-side silent-mic pre-flight (v0.3.13).
        // Compute RMS / peak / duration stats from the tap accumulators. If the
        // recording is too short or too quiet, abort the pipeline BEFORE calling
        // Deepgram. User directive: no error dialog — just log at .warning severity
        // and close the popup cleanly. Thresholds from Apple Developer Forum 710820
        // (speech sits at -40 to -20 dBFS, silence below -60 dBFS) and Forasoft's
        // silence trimming guide. See plan file abstract-rolling-babbage.md Commit 6.
        let stats = appState.audioRecorder.getRecordingStats()
        logger.info("\(logPrefix): recording stats: duration=\(String(format: "%.2f", stats.durationSec))s peak=\(String(format: "%.1f", stats.peakDBFS))dBFS mean=\(String(format: "%.1f", stats.meanDBFS))dBFS")

        // Duration floor: Deepgram returns empty transcripts for clips under ~0.5s.
        if stats.durationSec < 0.5 {
            logger.info("\(logPrefix): recording too short (\(String(format: "%.2f", stats.durationSec))s) — log-only, no user dialog")
            appState.errorService.addError(
                source: .deepgram,
                severity: .warning,
                message: "No speech detected",
                details: "Recording too short: \(String(format: "%.2f", stats.durationSec))s",
                actionable: false, transient: true,
                code: "deepgram.no_speech_detected"
            )
            appState.audioRecorder.cancelRecording()
            onClose()
            return nil
        }

        // RMS silence guard: peak < -45 dBFS AND mean < -50 dBFS indicates silent mic.
        // The AND condition gives near-zero false negatives on real speech: a real
        // recording with even one brief louder moment will have peak > -45 dBFS.
        //
        // v0.3.21 (P2 #5 Stage 2): tightened from -50/-55 → -45/-50 per the plan.
        // Catches more "above-old-threshold-but-still-silent" cases (background noise,
        // far mic) while staying conservative enough to never reject a real whisper.
        if stats.peakDBFS < -45 && stats.meanDBFS < -50 {
            logger.info("\(logPrefix): silent recording — log-only, no user dialog")
            appState.errorService.addError(
                source: .deepgram,
                severity: .warning,
                message: "No speech detected",
                details: "Silent recording: peak=\(String(format: "%.1f", stats.peakDBFS))dBFS mean=\(String(format: "%.1f", stats.meanDBFS))dBFS duration=\(String(format: "%.1f", stats.durationSec))s",
                actionable: false, transient: true,
                code: "deepgram.no_speech_detected"
            )
            appState.audioRecorder.cancelRecording()
            onClose()
            return nil
        }

        // 2. Get audio data (and clean up temp file)
        let audioStart = CFAbsoluteTimeGetCurrent()
        guard let wavData = appState.audioRecorder.getAudioData() else {
            logger.error("\(logPrefix): no audio data")
            appState.errorService.addError(source: .audioRecorder, severity: .error, message: "No audio data recorded")
            popupState = .error("No audio data recorded")
            // Ensure temp file cleanup on error
            appState.audioRecorder.cancelRecording()
            return nil
        }
        logger.pipelineStep("audio capture", duration: CFAbsoluteTimeGetCurrent() - audioStart)
        logger.info("\(logPrefix): got \(wavData.count) bytes of audio")

        // 3. Transcribe with Deepgram
        let transcript: String
        do {
            let transcribeStart = CFAbsoluteTimeGetCurrent()
            logger.info("\(logPrefix): sending to Deepgram...")
            transcript = try await appState.deepgramService.transcribeAudio(
                wavData: wavData,
                apiKey: appState.settings.deepgramAPIKey,
                model: appState.settings.deepgramModel,
                keyterms: appState.settings.deepgramKeyterms,
                vocabularyEnabled: appState.settings.deepgramVocabularyEnabled
            )
            logger.pipelineStep("Deepgram transcription", duration: CFAbsoluteTimeGetCurrent() - transcribeStart)
            logger.info("\(logPrefix): transcript received (\(transcript.count) chars): \(transcript)")
        } catch DeepgramService.DeepgramError.noSpeechDetected(let duration) {
            // v0.3.13: Deepgram confirmed empty transcript for audio >=0.5s.
            // This is the documented response for silent audio (discussions #765,
            // #713, #756). NOT a user-facing error per user directive. Log at
            // .warning severity for observability, close popup cleanly.
            //
            // v0.3.21 (P2 #5 Stage 2): mark transient so the Errors-tab UI folds
            // these into a single summary row instead of showing 26 individual
            // entries (65% of the pre-v0.3.14 visible Errors-tab volume).
            logger.info("\(logPrefix): Deepgram noSpeechDetected (duration=\(duration)s) — log-only, no user dialog")
            appState.errorService.addError(
                source: .deepgram,
                severity: .warning,
                message: "No speech detected",
                details: "Deepgram empty transcript for \(String(format: "%.1f", duration))s audio",
                actionable: false, transient: true,
                code: "deepgram.no_speech_detected"
            )
            onClose()
            return nil
        } catch DeepgramService.DeepgramError.transcriptionFailed(let requestId) {
            // v0.3.13: 200 OK with duration=0 or other odd state. Real service glitch —
            // log at .error severity and show a user-facing dialog. request_id is
            // kept so we can file Deepgram support tickets with a specific trace ID.
            logger.error("\(logPrefix): Deepgram transcriptionFailed (request_id=\(requestId ?? "-"))")
            appState.errorService.addError(
                source: .deepgram,
                severity: .error,
                message: "Transcription failed",
                details: "Deepgram returned empty result",
                requestId: requestId,
                code: "deepgram.transcription_failed"
            )
            popupState = .error("Transcription failed. Please try again.")
            return nil
        } catch {
            // P0 cross-cutting A: capture dg-request-id so the user can paste it
            // into a Deepgram support ticket.
            let requestId = (error as? DeepgramService.DeepgramError)?.requestId
            logger.error("\(logPrefix): transcription failed - \(error) request_id=\(requestId ?? "-")")
            appState.errorService.addError(
                source: .deepgram,
                severity: .error,
                message: "Transcription failed",
                details: error.localizedDescription,
                requestId: requestId,
                code: "deepgram.transcription_error"
            )
            popupState = .error("Transcription failed: \(error.localizedDescription)")
            return nil
        }

        // 3a. Save transcript to history immediately (progressive save)
        let entryId = appState.historyService.addEntry(transcript: transcript)
        logger.info("\(logPrefix): saved transcript to history (entry: \(entryId))")

        // 4. Process with LLM (if enabled)
        if appState.settings.sendToLLMEnabled {
            popupState = .processing
            do {
                let llmStart = CFAbsoluteTimeGetCurrent()
                logger.info("\(logPrefix): sending to OpenRouter model \(appState.settings.selectedModel) (temperature: \(appState.settings.temperature))...")
                let responseText = try await appState.openRouterService.processText(
                    transcript: transcript,
                    systemPrompt: appState.settings.systemPrompt,
                    model: appState.settings.selectedModel,
                    apiKey: appState.settings.openRouterAPIKey,
                    temperature: appState.settings.temperature
                )
                logger.pipelineStep("OpenRouter LLM", duration: CFAbsoluteTimeGetCurrent() - llmStart)
                logger.info("\(logPrefix): LLM response received (\(responseText.count) chars): \(responseText)")

                // Update the same history entry with LLM response
                appState.historyService.updateEntry(id: entryId, llmResponse: responseText)

                logger.pipelineStep("total pipeline", duration: CFAbsoluteTimeGetCurrent() - pipelineStart)
                return responseText
            } catch {
                // P0 cross-cutting A: capture X-Generation-Id so the user can paste it
                // into an OpenRouter support ticket.
                let requestId = (error as? OpenRouterService.OpenRouterError)?.requestId
                logger.error("\(logPrefix): LLM failed - \(error) X-Generation-Id=\(requestId ?? "-")")
                appState.errorService.addError(
                    source: .openRouter,
                    severity: .error,
                    message: "LLM processing failed",
                    details: error.localizedDescription,
                    requestId: requestId,
                    code: "openrouter.llm_failed"
                )
                popupState = .error("LLM processing failed: \(error.localizedDescription)")
                // Transcript is already saved to history
                return nil
            }
        } else {
            logger.info("\(logPrefix): LLM disabled, using raw transcript")
            logger.pipelineStep("total pipeline (no LLM)", duration: CFAbsoluteTimeGetCurrent() - pipelineStart)
            return transcript
        }
    }

    private func focusTargetApp(logPrefix: String) async {
        let logger = appState.logger

        // 5. Determine the target app for insertion.
        //    Use the app that was frontmost when we opened the popup.
        //    But also check current frontmost as a fallback — the user may have
        //    switched apps while recording (in that case, we still try previousApp).
        let targetApp = RecordingPopupController.shared.previousApp
        let currentFront = NSWorkspace.shared.frontmostApplication
        logger.info("\(logPrefix): target app (from popup open): \(targetApp?.localizedName ?? "nil") (pid: \(targetApp?.processIdentifier ?? 0))")
        logger.info("\(logPrefix): current frontmost: \(currentFront?.localizedName ?? "nil") (pid: \(currentFront?.processIdentifier ?? 0))")

        // 6. Close popup
        logger.info("\(logPrefix): closing popup...")
        onClose()

        // P1 #7: cooperative activation (macOS 14+).
        //
        // Pre-v0.3.17 used `NSApp.deactivate()` + `targetApp.activate()`. The
        // panel uses `.nonActivatingPanel` so VoicePolish never *had* focus to
        // deactivate — `deactivate()` was effectively noise that opened a race
        // window where notifications / `CoreServicesUIAgent` / Spotlight could
        // grab focus before our `activate()` landed (observed May 2: focus
        // went to Chrome instead of VS Code).
        //
        // `NSApp.yieldActivation(to:)` is the canonical macOS 14+ replacement
        // (Apple's "Passing control from one app to another with cooperative
        // activation" guide). `target.activate()` then completes the hand-off.
        // Ref: https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation
        if let targetApp {
            logger.info("\(logPrefix): yielding activation to \(targetApp.localizedName ?? "unknown") (\(targetApp.bundleIdentifier ?? "nil") pid: \(targetApp.processIdentifier))...")
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
        }

        // Wait for focus transfer — 500ms to be safe
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Log which app is now frontmost after activation (with bundle ID so
        // post-incident analysis can identify focus-stealing offenders).
        let frontApp = NSWorkspace.shared.frontmostApplication
        logger.info("\(logPrefix): frontmost app after activation: \(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil") pid: \(frontApp?.processIdentifier ?? 0))")

        // Verify the correct app got focus
        if let targetApp, frontApp?.processIdentifier != targetApp.processIdentifier {
            logger.error("\(logPrefix): WARNING - focus went to \(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil")) instead of \(targetApp.localizedName ?? "nil") (\(targetApp.bundleIdentifier ?? "nil")). Retrying activation...")
            // P0 #4: surface as transient observability so the noise floor of
            // focus-steal incidents is visible (driven by macOS, not our code).
            appState.errorService.addError(
                source: .textInsertion, severity: .warning,
                message: "Focus stolen by \(frontApp?.localizedName ?? "another app")",
                details: "Wanted \(targetApp.bundleIdentifier ?? targetApp.localizedName ?? "target"); got \(frontApp?.bundleIdentifier ?? frontApp?.localizedName ?? "nil"). Retrying.",
                actionable: false, transient: true,
                code: "focus.stolen_by_third_app"
            )
            NSApp.yieldActivation(to: targetApp)
            targetApp.activate()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let retryFront = NSWorkspace.shared.frontmostApplication
            logger.info("\(logPrefix): after retry, frontmost is: \(retryFront?.localizedName ?? "nil") (\(retryFront?.bundleIdentifier ?? "nil") pid: \(retryFront?.processIdentifier ?? 0))")
        }
    }

    private enum DeliveryMode {
        case normal
        case citrixTyping

        var logPrefix: String {
            switch self {
            case .normal: return "stopAndSend"
            case .citrixTyping: return "stopAndCitrixSend"
            }
        }
    }

    /// Maintains the silence detection state machine for the live mic indicator
    /// (v0.3.22, P2 #5 Stage 3). Called from the audio-level `onChange`. After
    /// 1 second of continuous silence below `silenceLevelThreshold`, flips
    /// `silentTooLong` true so the bar turns red and the warning label appears.
    /// Resets immediately when level recovers.
    private func updateSilenceState(level: Float) {
        if level < silenceLevelThreshold {
            // Level still silent — start the 1s grace timer if we haven't yet.
            if silentSinceTime == nil {
                silentSinceTime = Date()
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                    Task { @MainActor in silentTooLong = true }
                }
            }
        } else {
            // Level recovered — clear the indicator immediately.
            silentSinceTime = nil
            silentTooLong = false
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
    }
}
