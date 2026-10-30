import SwiftUI
import KeyboardShortcuts

@main
struct VoicePolishApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("VoicePolish", systemImage: menuBarIcon) {
            SettingsView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }

    /// A typing run has no popup and no Stop button — this icon swap is the only
    /// feedback the user gets that the app is mid-run.
    private var menuBarIcon: String {
        appState.textInsertionService.isTyping ? "keyboard.fill" : "mic.fill"
    }
}

/// Exists solely to drain held modifier keys on quit.
///
/// `defer { emitter.unwind() }` covers throw, return and cancellation, but not
/// the user picking Quit mid-run: the process exits and the defer never runs. A
/// modifier latched on a remote machine has no recovery short of physically
/// pressing the key.
///
/// The drain is gated on a run actually being in flight and touches only Shift
/// and Option -- firing on every quit would desync a modifier the user happens
/// to be holding while quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        KeystrokeTypingEngine.drainModifiersOnTerminate()
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

    /// Set to `true` by the stop-and-type hotkey to tell the popup view to trigger stopAndCitrixSend.
    var shouldStopAndType = false

    /// Observable mirror of `RecordingPopupController.isShowing` (a plain NSObject the
    /// menubar control bar can't observe). Set in `showPopup`, cleared in `windowWillClose`.
    var isPopupShowing = false

    enum RecordingControlState {
        case idle
        /// Recording or paused — Stop & Paste / Stop & Type / Discard apply.
        case recording
        /// Popup up but not recording: transcribing, processing, error, or engine recovery.
        case busy
        /// A keystroke typing run is in flight (it outlives its popup).
        case typing
    }

    /// Drives which menubar control-bar buttons are enabled.
    var controlState: RecordingControlState {
        if isPopupShowing {
            switch audioRecorder.state {
            case .recording, .paused: return .recording
            default: return .busy
            }
        }
        return textInsertionService.isTyping ? .typing : .idle
    }

    private var configChangeObserver: NSObjectProtocol?

    init() {
        for name in HotkeyAction.record.names {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                self?.toggleRecordingPopup()
            }
        }
        for name in HotkeyAction.discard.names {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                self?.discard()
            }
        }
        for name in HotkeyAction.stopAndType.names {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                self?.requestStopAndType()
            }
        }
        FrontmostAppTracker.shared.start()
        permissionManager.checkAndRequestPermissions()
        logger.info("VoicePolish started")

        // Monitor for audio engine configuration changes and recover proactively
        registerConfigChangeObserver()

        // v0.3.30: prune archived recordings on launch so the retention policy (default
        // 7-day age-out) reclaims disk even when no new recording happens this session.
        Task { @MainActor in
            let liveIDs = Set(HistoryService.shared.entries.map(\.id))
            await AudioStorageService.shared.prune(policy: AppSettings.shared.audioRetentionPolicy,
                                                   liveEntryIDs: liveIDs)
        }

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

    /// Discard whatever is in flight: an active recording, a transcription/LLM
    /// pipeline (so it never ghost-pastes), or a keystroke typing run. Shared by the
    /// cancel hotkeys and the menubar Discard button.
    func discard() {
        let controller = RecordingPopupController.shared

        // A keystroke typing run outlives its popup: focusTargetApp() closes the
        // popup BEFORE typing starts, so `isShowing` is false for the whole run
        // and the guard below would make Cmd+[ a no-op — leaving a 30-120s run
        // with no way to stop it.
        //
        // Only take this branch when no popup is up. Otherwise a NEW recording
        // started during a long run would have its own Cmd+[ stolen by the
        // still-typing task, leaving that recording running and its popup open.
        if textInsertionService.isTyping, !controller.isShowing {
            logger.info("Discard — aborting in-flight typing run")
            controller.cancelPipeline()
            return
        }

        guard controller.isShowing else { return }
        if audioRecorder.state == .recording || audioRecorder.state == .paused {
            logger.info("Discard — cancelling recording")
            audioRecorder.cancelRecording()
        } else {
            // Popup is up but recording already stopped (transcribing/processing): Cmd+[
            // now cancels the in-flight pipeline too, so a dismissed run never ghost-pastes.
            logger.info("Discard — cancelling in-flight transcription pipeline")
        }
        controller.cancelPipeline()
        controller.closePopup(appState: self)
    }

    /// Stop the active recording and type the result key by key. No-op unless recording.
    func requestStopAndType() {
        guard isRecordingInPopup else { return }
        logger.info("Stop & Type requested — triggering stopAndCitrixSend")
        shouldStopAndType = true
    }

    /// Stop the active recording and paste the result. No-op unless recording.
    func requestStopAndPaste() {
        guard isRecordingInPopup else { return }
        logger.info("Stop & Paste requested — triggering stopAndSend")
        shouldStopAndSend = true
    }

    private var isRecordingInPopup: Bool {
        RecordingPopupController.shared.isShowing
            && (audioRecorder.state == .recording || audioRecorder.state == .paused)
    }

    // MARK: - Retry from history (v0.3.30)

    /// The history entry currently being retried (drives the card's spinner). nil = idle.
    var retryingEntryId: UUID? = nil
    private var retryTask: Task<Void, Never>?

    func cancelRetry() { retryTask?.cancel() }

    /// Re-run a failed history entry from its saved audio (transcription failure) or re-run
    /// only the LLM (LLM failure), updating the entry in place. No paste — the user copies
    /// the result from History (delivery = update-entry-only). Single-flight.
    func retryHistoryEntry(id: UUID) {
        guard retryingEntryId == nil,
              let entry = historyService.entries.first(where: { $0.id == id }) else { return }
        retryingEntryId = id
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryingEntryId = nil }
            await self.runRetry(entry: entry)
        }
    }

    private func runRetry(entry: HistoryEntry) async {
        let id = entry.id
        // Track where we are so a failure is labelled correctly (transcription vs LLM).
        var stage: HistoryEntry.FailureStage = entry.failureStage ?? .transcription
        do {
            // 1. Obtain the transcript: reuse it for an LLM-stage failure, otherwise
            //    re-transcribe from the saved audio.
            let transcript: String
            if stage == .llm, !entry.transcript.isEmpty {
                transcript = entry.transcript
            } else {
                stage = .transcription
                guard let wav = await AudioStorageService.shared.load(for: id) else {
                    historyService.markFailed(id: id, stage: .transcription,
                                              errorMessage: "Audio no longer available")
                    return
                }
                transcript = try await deepgramService.transcribeAudio(
                    wavData: wav,
                    apiKey: settings.deepgramAPIKey,
                    model: settings.deepgramModel,
                    keyterms: settings.deepgramKeyterms,
                    vocabularyEnabled: settings.deepgramVocabularyEnabled
                )
                // Progressive save (mirrors the main pipeline): persist the fresh transcript
                // BEFORE the LLM step so an LLM failure can't discard it or mislabel the entry.
                historyService.updateTranscript(id: id, transcript: transcript)
            }

            // 2. LLM (if enabled).
            var llmResponse: String? = nil
            if settings.sendToLLMEnabled {
                stage = .llm
                llmResponse = try await openRouterService.processText(
                    transcript: transcript,
                    systemPrompt: settings.systemPrompt,
                    model: settings.selectedModel,
                    apiKey: settings.openRouterAPIKey,
                    temperature: settings.temperature
                )
            }

            if Task.isCancelled { return }  // leave the entry failed; no partial write

            // 3. Success: update the entry in place and honor the save scope.
            historyService.applyRetrySuccess(id: id, transcript: transcript, llmResponse: llmResponse)
            if !settings.archiveSuccessfulRecordings { historyService.clearAudio(id: id) }
            logger.info("Retry succeeded for history entry \(id)")
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                logger.info("Retry cancelled for history entry \(id)")
                return  // entry stays failed, no new error surfaced
            }
            logger.error("Retry failed for history entry \(id): \(error)")
            historyService.markFailed(id: id, stage: stage, errorMessage: error.localizedDescription)
        }
    }

    func toggleRecordingPopup() {
        let controller = RecordingPopupController.shared
        if controller.isShowing {
            // If currently recording or paused, trigger stop & send via the flag
            if audioRecorder.state == .recording || audioRecorder.state == .paused {
                logger.info("Hotkey pressed while recording — triggering stopAndSend")
                shouldStopAndSend = true
            } else {
                // Not recording (idle, transcribing, etc.) — cancel any in-flight pipeline
                // so a dismissed transcription never ghost-pastes, then close.
                controller.cancelPipeline()
                controller.closePopup(appState: self)
            }
        } else {
            startRecording()
        }
    }

    /// Required settings missing for a recording, or nil when ready. Lets the menubar
    /// control bar show the reason inline instead of the click silently doing nothing.
    func startPreflightError() -> StartPreflightError? {
        if settings.deepgramAPIKey.isEmpty { return .deepgramKeyMissing }
        if settings.sendToLLMEnabled, settings.openRouterAPIKey.isEmpty { return .openRouterKeyMissing }
        return nil
    }

    enum StartPreflightError {
        case deepgramKeyMissing
        case openRouterKeyMissing

        var message: String {
            switch self {
            case .deepgramKeyMissing: return "Deepgram API key not configured"
            case .openRouterKeyMissing: return "OpenRouter API key not configured"
            }
        }

        var details: String {
            switch self {
            case .deepgramKeyMissing: return "Open Settings and paste your Deepgram API key."
            case .openRouterKeyMissing: return "Open Settings and paste your OpenRouter API key, or disable Send to LLM."
            }
        }

        var code: String {
            switch self {
            case .deepgramKeyMissing: return "settings.deepgram_key_missing"
            case .openRouterKeyMissing: return "settings.openrouter_key_missing"
            }
        }
    }

    /// Start a recording and show the popup. No-op if the popup is already up.
    func startRecording() {
        let controller = RecordingPopupController.shared
        guard !controller.isShowing else { return }

        if let preflight = startPreflightError() {
            logger.error(preflight.message)
            errorService.addError(
                source: .general, severity: .error,
                message: preflight.message,
                details: preflight.details,
                code: preflight.code
            )
            return
        }

        permissionManager.checkMicrophonePermission()

        // Start recording BEFORE showing popup to eliminate SwiftUI rendering delay.
        // Audio capture begins the instant the hotkey (or menubar Record) is pressed.
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
        } catch let AudioRecorder.RecorderError.engineRecycleNeeded(ageHours) {
            // P2 #3 (v0.3.19): engine has been alive past the 4h threshold.
            // Soft-recycle (full teardown + warmup) before starting the recording
            // so accumulated state doesn't carry over. Costs ~200ms of cold start.
            logger.info("Soft engine recycle requested (alive \(String(format: "%.1f", ageHours))h)")
            controller.showPopup(appState: self)
            Task { @MainActor in
                do {
                    try await audioRecorder.recycleEngine(reason: "engine alive \(String(format: "%.1f", ageHours))h, exceeded 4h threshold")
                    try audioRecorder.startRecording()
                    logger.info("Soft recycle complete, recording started")
                } catch {
                    logger.error("Soft recycle failed: \(error)")
                    errorService.addError(source: .audioRecorder, severity: .error, message: "Soft engine recycle failed", details: error.localizedDescription)
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
