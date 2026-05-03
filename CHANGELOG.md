# Changelog

## Versioning Scheme

VoicePolish uses a three-part version: **`MAJOR.DEPLOY.LOCAL`**

| Segment  | Meaning | When it changes |
|----------|---------|-----------------|
| `MAJOR`  | Breaking changes or major milestones | Significant redesign or incompatible changes |
| `DEPLOY` | Each production-ready deployed version | Incremented when a version is pushed to production; `LOCAL` resets to `0` |
| `LOCAL`  | Each locally tested iteration | Incremented on every local build/test cycle during development |

### Examples

```
0.1.0  — First deployed version (production)
0.1.1  — First local test after 0.1.0
0.1.2  — Second local test (found and fixed an issue)
0.1.3  — Third local test
0.2.0  — Pushed to production (LOCAL resets to 0)
0.2.1  — First local test after 0.2.0
1.0.0  — Major milestone release
```

### How to update the version

1. Edit the `VERSION` file in the project root (single line, e.g. `0.2.0`)
2. The app reads this file at build time via the `AppVersion` constant
3. Add a new entry to this changelog under the appropriate version heading

Claude Code can update the `VERSION` file and this changelog when asked.

---

## [0.3.26] — 2026-05-02

### Fixed
- **Silent recordings caused by denied microphone permission now surface clearly.** Pre-v0.3.26, macOS silently fed all-zero buffers when `kTCCServiceMicrophone` was denied — recordings completed with `peak=-100 dBFS / mean=-100 dBFS` and no diagnostic anywhere (the warmup tap firing didn't tell the user the data was actually empty). The May 2 production report was exactly this: AirPods connected, engine warming up cleanly, but the mic-level bar stayed flat at zero because TCC had been reset.
  - **`PermissionManager.checkMicrophonePermission`** now logs the explicit status (`AUTHORIZED` / `NOT_DETERMINED` / `DENIED` / `RESTRICTED`) and, when denied or restricted, emits an actionable Errors-tab entry with concrete instructions: "Open System Settings → Privacy & Security → Microphone and enable VoicePolish, then restart the app."
  - On `NOT_DETERMINED` → triggers the system prompt and logs the result.
  - Codes: `permission.microphone_denied`, `permission.microphone_restricted`.
- **Accessibility permission status** is now logged at startup as well (was silent before).

### Notes
- Verification: `tccutil reset Microphone com.voicepolish.app`, restart the app — should see "Microphone permission: NOT_DETERMINED — requesting via system prompt", system dialog appears, grant → "Microphone permission request result: GRANTED" follows. Tap the recording hotkey, mic-level bar should respond to your voice.

---

## [0.3.25] — 2026-05-02

### Fixed
- **Phantom `AVAudioEngineConfigurationChange` storm with AirPods (and other Bluetooth headsets).** Pre-v0.3.25, every config-change notification triggered a full engine teardown + warmup, even when nothing about the audio device had actually changed. AirPods fire these notifications every 1-3 seconds while sitting idle, so the engine was being torn down ~20× per minute and never stayed `.running` long enough for the recording popup to use it. Symptom: "I press the hotkey but recording never actually starts" (May 2 production report).
  - **Fix**: snapshot the default input device ID + sample rate after every successful warmup. In `performEngineRestart`, if engine state is `.running` AND both still match the snapshot, log "phantom config change" and skip the restart entirely. Genuine device/rate changes still rebuild the engine; broken/stopped engines still rebuild unconditionally.
  - This is the documented AirPods aggregate-device behaviour from Liscio's blog and Stack Overflow #63537851. The plan recommended deferring `inputNode` access to mitigate this; the dedup approach is more direct.

### Notes
- Verification: connect AirPods, open the app, leave idle for 30 s. The log should show "Skipping engine restart — phantom config change" entries instead of repeated "Old engine torn down - Starting fresh warmup" cycles. Hotkey-to-record latency should drop back to ~0ms.

---

## [0.3.24] — 2026-05-02

### Added
- **90-day log retention** (P2 cross-cutting C). `LoggingService.cleanupOldLogs(olderThanDays:)` runs at app init and deletes `voicepolish-*.log` files in `~/Library/Logs/VoicePolish/` whose mtime is older than 90 days. Pre-v0.3.24 the only retention was macOS's own (none observed), leaving us with only ~11 days of historical comparison data. 90 days lets us compare the current error rate against the previous month's baseline.
- **Metrics rollup footer in the Errors tab.** Derived live from `HistoryService` (success count) and `ErrorService` (actionable + transient counts) for the active time filter — no separate `metrics.json` needed. Shows: `N recordings · M actionable · K transient · X% success` (success rate green ≥95%, orange below).

### Notes
- Final commit in the post-hardening observability pass (v0.3.14 → v0.3.24). Next version bump to **0.4.0** when shipping to production SaaS per the plan's verification gate. Plan file: `~/.claude/plans/there-are-quite-a-abstract-peach.md`.

---

## [0.3.23] — 2026-05-02

### Added
- **Inner 1-second timeout per CoreAudio format query** (P2 cross-cutting B). `inputNode.outputFormat(forBus: 0)` and `inputNode.inputFormat(forBus: 0)` are now each wrapped in a `withThrowingTaskGroup` race against a 1-second sleep inside the existing detached engine-creation task.
  - Defense in depth for the Apr 30 2026 27.8-minute hang. The outer 10-second warmup race already caught the whole pass; these inner caps fail fast and identify *which specific* CoreAudio call hung (logged with the call label, e.g. `inputNode.outputFormat(forBus:0) exceeded 1000ms`).
  - Throws `RecorderError.coreAudioStuck` (transient — routes to backoff ladder).
- **`AudioRecorder.raceWithTimeout(seconds:label:operation:)` static helper** (private). Generic over `Sendable T`, uses the optional-as-discriminator pattern (Swift 6 generic functions can't host nested types). Cancellation can't interrupt the underlying synchronous CoreAudio call but the caller is released.
- Format fields (sampleRate, channels, commonFormat, isInterleaved) are extracted into a Sendable tuple inside the timed closure so the value can cross the task-group boundary cleanly without `@unchecked Sendable` wrappers around `AVAudioFormat`.

### Notes
- Verification: `sudo killall -STOP coreaudiod`, trigger a recording — the warmup attempt should now fail in ~1 s with a log line identifying which format call hung, rather than waiting on the outer 10 s cap.

---

## [0.3.22] — 2026-05-02

### Added
- **Live mic level feedback in the recording popup** (P2 #5 Stage 3). The existing audio-level bar now turns red and shows a "Microphone appears silent — check input device" caption after 1 second of continuous silence below `audioLevel` 0.02 (≈-34 dBFS). Resets immediately when the level recovers.
  - Addresses the underlying product UX problem behind "no speech detected" errors: pre-v0.3.22, the user couldn't tell their mic was dead until the empty transcript came back. The live indicator gives visual feedback during recording so muted-mic situations are caught before the user releases the hotkey.
  - Implementation: `silentSinceTime`/`silentTooLong`/`silenceTimer` state machine on `RecordingPopupView`, driven by `.onChange(of: audioLevel)`. Bar fill switches between `Color.green.gradient` and `Color.red.gradient`.

### Notes
- Verification: open the recording popup, mute the system mic in System Settings → Sound. Within 1 s the bar should turn red and the warning caption appear. Unmute — bar should return to green and caption disappear immediately.
- Expected impact (per plan verification): `noSpeechDetected` count in `errors.json` drops by ≥40% over a 7-day comparable usage window.

---

## [0.3.21] — 2026-05-02

### Changed
- **Tightened silent-mic preflight thresholds** (P2 #5 Stage 2) from `peak < -50 AND mean < -55` to `peak < -45 AND mean < -50`. Catches more "above-old-threshold-but-still-silent" cases (background noise, far mic) while staying conservative enough that a real whisper still passes (real speech sits at -40 to -20 dBFS per Apple Developer Forum 710820).
- **All three "No speech detected" emission paths now mark the entry transient** (`actionable: false, transient: true, code: "deepgram.no_speech_detected"`):
  - Client-side preflight: too short (<0.5s)
  - Client-side preflight: silent mic (below dBFS thresholds)
  - Deepgram server-side empty transcript (≥0.5s)
  These collapse into a single Errors-tab summary row ("No speech detected — N times in last X, last: Y") instead of 26 individual entries (65% of the pre-v0.3.14 visible Errors-tab volume).

### Notes
- Verification: errors.json `noSpeechDetected` count over a 7-day window may stay similar — the underlying behavior is unchanged. The visible row count in the Errors tab should drop from ~26 to **1** (the summary row).

---

## [0.3.20] — 2026-05-02

### Added
- **Expanded HAL transient whitelist** (P2 #6). Two additional CoreAudio HAL error codes now route to the recovery backoff ladder instead of `.broken`:
  - `kAudioHardwareUnspecifiedError` (`'what'`, 2003329396) — generic, often resolves on retry per the CoreAudio header reference.
  - `kAudioDeviceUnsupportedFormatError` (`'!dat'`, 560226676) — handled via the fresh format query in the next warmup attempt (the v0.3.10 stale-format reconciliation does the renegotiation automatically).
- **Symbolic constants** replace the hardcoded 560227702/1937010544/560161383 literals so the whitelist is maintainable.
- **`AudioRecorder.fourCharCodeString(_:)` helper** renders an OSStatus code as its FourCharCode representation (e.g. `560227702` → `'!dev'`). Unknown HAL codes that fall through the whitelist are now logged with their FourCC so future field data can identify additional transient candidates and graduate them to the whitelist.

### Notes
- Codes that remain *permanent* (NOT in the whitelist): `kAudioHardwareBadObjectError` (invalid reference), `kAudioDevicePermissionsError` (requires user intervention).

---

## [0.3.19] — 2026-05-02

### Added
- **Soft engine recycle on long-running sessions** (P2 #3). `AudioRecorder` now stamps `engineStartedAt` on every successful warmup and throws `RecorderError.engineRecycleNeeded(ageHours:)` from `startRecording()` if the in-memory engine has been alive past `engineMaxAge` (4 hours). `VoicePolishApp.toggleRecordingPopup` catches the new error, calls the new `AudioRecorder.recycleEngine(reason:)` (full teardown + warmup), then proceeds with the recording. Invisible to active sessions; costs ~200ms cold start once every 4h.
- **Engine lifetime instrumentation**. `performGuardedWarmup` logs the previous engine instance's lifetime in minutes whenever a warmup completes, so triage of the May 1-2 baseline elevation (errors uncorrelated with device changes) has a concrete data point. Soft recycles also surface in the Errors-tab transient summary (`audio.engine.soft_recycle`).

### Fixed
- Hypothesis from the May 1-2 baseline: cumulative resource creep / macOS state degradation in the kept-running engine. The recycle is the cheapest defense — clean teardown breaks any accumulated state without abandoning the keep-engine-running optimization for the hot path.

### Notes
- Verification: leave the app idle for 4+ hours, then trigger a recording. The popup should briefly show warmup, the Errors-tab transient summary should show "Audio engine soft-recycled (engine alive 4.x h, exceeded 4h threshold)", and recording should start cleanly.

---

## [0.3.18] — 2026-05-02

### Added
- **`coreaudiod` fast-fail probe** (200ms HAL property query race) at the start of `performWarmup()`. Healthy daemons return in <10ms; if the probe times out, the daemon is presumed deadlocked and warmup throws `RecorderError.coreAudioStuck` immediately instead of letting `AVAudioEngine()` block for minutes.
  - Defends against the documented JUCE callback-vs-`AudioDeviceStart` deadlock pattern (JUCE Forum #51882). The Apr 30 2026 incident logged in `voicepolish-2026-04-30.log` shows a 27.8-minute hang in engine init at 18:35:30 UTC — exactly this failure mode. Probe converts that into a sub-second fail-fast.
  - When the probe trips, surfaces an actionable diagnostic in the Errors tab (`audio.coreaudiod_stuck`) telling the user to `sudo killall coreaudiod` and retry.
- **New `RecorderError.coreAudioStuck(String)` case** with `isTransient = true` so the next user-initiated recording can re-attempt without manual intervention if the daemon recovers.

### Notes
- Verification: `sudo killall -STOP coreaudiod` (suspend the daemon), trigger a recording — the warmup attempt should fail in <500ms with the new diagnostic in the Errors tab. Then `sudo killall -CONT coreaudiod` and verify recovery.
- Cancellation cannot interrupt the underlying synchronous CoreAudio call — orphaned probe tasks may still complete in the background. The point is to release the *caller* fast so the user sees the issue.

---

## [0.3.17] — 2026-05-02

### Changed
- **Cooperative activation (macOS 14+) for target-app focus restoration.** Replaced `NSApp.deactivate()` + `targetApp.activate()` with `NSApp.yieldActivation(to: targetApp)` + `targetApp.activate()`. The popup uses `.nonActivatingPanel` so VoicePolish never *had* focus to deactivate — `deactivate()` was opening a race window where `CoreServicesUIAgent` / Spotlight / notifications could grab focus before our `activate()` landed (observed May 2: focus went to Chrome instead of VS Code). `yieldActivation(to:)` is the canonical replacement per Apple's cooperative-activation guide.
- **Post-paste clipboard-restore wait bumped 200ms → 500ms.** Industry consensus (Igor Kulman, Multi.app) is that 200ms is too short for Electron-based apps (Slack, Discord, the VS Code Electron host); 500ms gives the target's paste handler time to consume the pasteboard before we restore the user's previous clipboard contents.
- **Bundle-ID logging** in focus restoration logs (`localizedName (bundle.id pid:N)`) so post-incident analysis can identify focus-stealing offenders.

### Added
- **Transient `focus.stolen_by_third_app` warning** emitted when the wrong app gets focus on first activation. Surfaces in the Errors-tab transient summary so the noise floor of macOS focus-steal incidents (driven by the OS, not our code — Apple has no `ForegroundLockTimeout` equivalent) is visible without nagging the user.

### Notes
- Verification: paste into VS Code, Chrome, Slack, Discord, Notion, Terminal in sequence with no manual focus. 100% paste success rate expected; "focus went to wrong app" warnings should drop to near zero.

---

## [0.3.16] — 2026-05-02

### Fixed
- **Actor-style serialization for `AudioRecorder.warmUp()`** — eliminates the `Swift.CancellationError` cascade that dominated the audio-engine error count in Apr-May logs (14 occurrences in 11 days, 10 in a single second on Apr 30).
  - **Root cause**: pre-v0.3.16 logic force-cancelled any in-flight warmup whenever a second `AVAudioEngineConfigurationChange` fired during the first warmup's 3-second first-buffer wait. The cancelled task threw `Swift.CancellationError` into the original caller's `await`, even though the second warmup would have produced the same engine state.
  - **Fix**: new requests JOIN the in-flight warmup via `try await existing.value` instead of cancelling. Only one engine-creation pass runs per warmup window; all callers see the same result. `recoverEngine()` and `performEngineRestart()` retain their explicit cancel-and-retry behaviour because they intentionally start fresh after a teardown.
  - Apple Developer Forum #772380 + WWDC 2025 #268 confirm this is the canonical Swift 6 pattern for serializing async state.

### Refactored
- Pulled the 10-second outer timeout, the success state transition, and the transient/permanent HAL classification out of `warmUp()` into a private `performGuardedWarmup()` so the join path benefits from the same protection without duplicating logic.

### Notes
- Verification: stress-test with rapid AirPods reconnects (toggle Bluetooth 5× in 30s). The `Warmup already in progress, force-cancelling old task and retrying` log line should drop to **0 occurrences** post-v0.3.16. Total audio-engine error count expected to drop ~60% (per the plan's projection).

---

## [0.3.15] — 2026-05-02

### Added
- **Deepgram `dg-request-id` header capture on errors.** Non-200 responses now carry the canonical Deepgram trace ID even when the response body is malformed. `DeepgramError.apiError` gains a `requestId` associated value, and `DeepgramError.requestId` exposes a uniform getter so the popup can route IDs to `ErrorService.addError(requestId:)` regardless of which error case fired.
- **Deepgram `?tag=voicepolish-{version}` query parameter** on every `/v1/listen` request so Deepgram's project-level analytics (List Project Requests endpoint) can filter VoicePolish traffic by version. URL-encoded.
- **OpenRouter `X-Generation-Id` header capture on every response** (success and error paths). Added `requestId` to `OpenRouterError.apiError` and `OpenRouterError.emptyResponse`, plus a uniform `OpenRouterError.requestId` getter. Falls back to `x-request-id` if `X-Generation-Id` is absent. Logged with usage tokens for observability.
- **`code:` parameter on transcription/LLM error entries**: `deepgram.transcription_failed`, `deepgram.transcription_error`, `openrouter.llm_failed` — drives the Errors-tab grouping introduced in v0.3.14.

### Changed
- `RecordingPopupView` catch blocks now extract the upstream request ID via the typed `requestId` getter (`(error as? DeepgramError)?.requestId`, `(error as? OpenRouterError)?.requestId`) and pass it through `ErrorService.addError(requestId:)`. The Errors tab card surfaces it inline with selectable text.

### Notes
- Verification: trigger a Deepgram 5xx (malform an API key) or an OpenRouter rate limit, confirm the request ID appears on the resulting Errors-tab entry. Without this, any future support ticket would be untraceable.

---

## [0.3.14] — 2026-05-02

### Added
- **`ErrorEntry.actionable`, `.transient`, `.requestId`, `.code` fields.** Every persisted error now carries enough metadata to drive UI grouping and support tickets. Backward-compatible Codable: pre-v0.3.14 entries decode with sensible defaults (`actionable: true`, `transient: false`).
- **`ErrorService.getDisplayEntries(filter:)`** — splits entries into actionable rows and transient summary groups so the Errors tab can show a calm view by default with an expandable "Transient (N)" block.
- **Transient warning emitted on every successful audio engine recovery** (`audio.engine.recovered`, attempts taken). Counts the noise floor of "engine was broken but recovered" without alarming the user.
- **Errors-tab UI grouping**: collapsible "Transient (N)" summary block; each group shows `count × source · message · last: relative-time`. Request-ID surfaced inline on individual error cards with `textSelection(.enabled)` so users can paste it into support tickets.

### Changed
- **Routed every previously console-only `logger.error()` call through `ErrorService.addError()`** so the Errors tab matches the raw log error count instead of silently undercounting (~33% gap pre-v0.3.14):
  - `DeepgramService.verifyAPIKey` — HTTP failure and network error paths (`deepgram.key_verification_*`)
  - `OpenRouterService.verifyAPIKey` — HTTP failure and network error paths (`openrouter.key_verification_*`)
  - `OpenRouterService.verifyModel` — both error branches and network error path (`openrouter.model_verification_*`)
  - `HistoryService.loadFromDisk` / `saveToDisk` — surfaces silent data-loss risk (`history.load_failed` / `history.save_failed`)
  - `TextInsertionService.insertText` — CGEvent creation failure (`text_insertion.cgevent_create_failed`)
  - `VoicePolishApp` initial warmup failure (transient, observability-only) and missing API-key guards (`settings.deepgram_key_missing`, `settings.openrouter_key_missing`)
- **`hasRecentErrors` now ignores transient + non-actionable entries** so the menubar dot only lights up on genuinely actionable problems.
- **`ErrorService.{load,save}FromDisk` errors stay console-only on purpose** — recursing through `addError()` would loop if the storage layer itself is the failure mode.

### Notes
- First commit in the post-hardening observability pass. Sets up the baseline that v0.3.15+ fixes can be measured against (verification target: errors.json count vs `grep -c ERROR voicepolish-*.log` gap drops from ~33% to <5%).

---

## [0.3.13] — 2026-04-11

### Changed
- **"No speech detected" is no longer a user-facing error — per user directive.** Split the old `DeepgramError.emptyTranscript` into two distinct cases:
  - `noSpeechDetected(durationSec:)` — Deepgram returned 200 OK with empty transcript on audio ≥ 0.5 s. This is the documented response for silent audio (Deepgram discussions #765, #713, #756). Logged at `.warning` severity in the Errors tab for operator observability, but no dialog is shown. Popup auto-closes cleanly.
  - `transcriptionFailed(requestId:)` — 200 OK but duration < 0.5 s or other odd state (real Deepgram glitch). Logged at `.error` severity with the `request_id` so Deepgram support tickets can be filed with a specific trace identifier. Dialog IS shown.

### Added
- **Client-side silent-mic pre-flight in `RecordingPopupView.stopAndSend()`.** Before uploading to Deepgram, compute RMS peak + mean dBFS + duration from tap accumulators and reject:
  - Recordings < 0.5 s (Deepgram minimum effective duration)
  - Recordings where `peakDBFS < -50 AND meanDBFS < -55` (silent mic)
  Both cases log at `.warning` severity and close the popup cleanly — no Deepgram round trip, no dialog. Saves API cost and provides instant feedback on muted-mic scenarios. Thresholds from Apple Developer Forum 710820 and Forasoft's silence-trimming guide.
- **`AudioRecorder.RecordingStats`** struct with `peakDBFS`, `meanDBFS`, `durationSec`. Populated from inside the tap callback alongside the existing `calculateLevel`. `getRecordingStats()` returns the stats for the most recently stopped recording.

### Notes
- This is the sixth and final commit in the SaaS-reliability hardening pass (v0.3.8-v0.3.13). Next version bump should be DEPLOY → 0.4.0 when shipping to production SaaS.

## [0.3.12] — 2026-04-11

### Fixed
- **Exponential backoff recovery ladder.** Replaced the one-shot `recoverEngine()` from `8fbcc0d` with a bounded 5-attempt ladder `[0, 250ms, 500ms, 1s, 2s, 5s]`. Total budget ~8.75s. Each attempt does a full WhisperKit-style teardown (`removeTap` → `disconnectNodeInput` → `stop` → `reset` → nil the engine) before re-warming, guaranteeing a clean graph every retry. `recoveryAttempt` counter is reset to 0 from inside the tap callback on first real buffer — the only rock-solid signal that recovery actually worked (not `engine.start()` returning, which v0.3.10 showed is insufficient).
- **`AVAudioEngineConfigurationChange` debounce 500 ms → 750 ms.** Community sources (`audiodog.co.uk`, Apple Developer Forums, Liscio's AirPods blog) confirm Bluetooth reconnects and USB-dock switches fire 2-4 notifications 500-1500 ms apart; 500 ms was catching mid-burst and triggering rebuilds against intermediate states.
- **"Audio engine broken" severity Critical → Warning.** With the backoff ladder in place, this event almost always auto-recovers within 8.75s. CRITICAL is now reserved for the `Engine recovery failed` path where the ladder actually exhausts.

## [0.3.11] — 2026-04-11

### Fixed
- **CoreAudio HAL preflight before engine creation.** Added `waitForDefaultInputDeviceReady(timeout: 1.5)` which polls `kAudioHardwarePropertyDefaultInputDevice` + `kAudioDevicePropertyDeviceIsAlive` + `kAudioDevicePropertyStreamConfiguration` every 75 ms. Closes the `kAudioHardwareBadDeviceError` (560227702 = `!dev`) race where the default input device ID becomes stale during a device swap but CoreAudio hasn't finished reconfiguring the graph. Follows SimplyCoreAudio's and SFBAudioEngine's canonical pattern.
- **Transient error classification in `warmUp()`.** Known transient HAL codes (`kAudioHardwareBadDeviceError`, `kAudioHardwareNotRunningError`, `kAudioHardwareIllegalOperationError`) now route to `.stopped` for retry instead of terminal `.broken`. Same for stale-format and no-buffers errors from v0.3.10. This sets up commit v0.3.12's backoff ladder — transient errors will walk the ladder; only genuinely unknown failures enter `.broken`.

## [0.3.10] — 2026-04-11

### Fixed
- **AVAudioEngine stale-format race — the biggest reliability fix.** After an `AVAudioEngineConfigurationChange` (Bluetooth reconnect, USB dock switch, headphone plug/unplug), `inputNode.outputFormat(forBus: 0)` briefly returns the previous device's format (sometimes `0 ch / 0 Hz`). Installing a tap with that stale format caused `engine.start()` to succeed *without throwing* but no audio buffer callbacks ever fired — the "No audio buffers received during warmup" error. Adopted the WhisperKit canonical pattern (`AudioProcessor.swift` ~L974): take `sampleRate` from `inputNode.inputFormat(forBus: 0)` (which always reflects real hardware) and the rest of the fields from `outputFormat(forBus: 0)`, then construct a fresh `AVAudioFormat` and install that on the tap. Validates non-zero values before install.
- **First-buffer detection moved inside the tap callback.** The old 50 ms polling loop sampled `lastBufferTimestamp` from outside the tap thread, creating a subtle race. The new `firstBufferReceived` flag is set from within the tap block on first invocation and waited on via `withThrowingTaskGroup`. Wait window bumped from 2 s to 3 s (Apple Developer Forum thread 683348 documents 500 ms+ settle times post-device-swap). Healthy graph still returns in ~100-150 ms.

## [0.3.9] — 2026-04-11

### Fixed
- **Deepgram retry logic rewritten as iterative exponential backoff with jitter.** The old recursive 429 retry path from `8fbcc0d` had no attempt cap, no exponential growth, and no jitter — a sustained rate-limit streak could spin the app and contribute to a thundering-herd incident. Replaced with an iterative loop over `{408, 429, 500, 502, 503, 504}`, max 3 retries (4 total requests), delay = `min(max(Retry-After, 2^attempt + random(0..1)), 32s)`, honoring `Retry-After` on all retryable codes. Never retries on 400/401/403/404.

## [0.3.8] — 2026-04-11

### Added
- **Deepgram response instrumentation** (observability-only, zero behavioral change). The `DeepgramResponse` struct now decodes `metadata.duration`, `metadata.request_id`, and `alternatives[0].words[]`. Every `/v1/listen` call logs a `[Deepgram] request_id=... duration=... confidence=... wordCount=...` line so silent-mic, too-short-clip, and real Deepgram glitches can be distinguished in a week's worth of production logs. First commit in the SaaS-reliability pass — unblocks threshold tuning for later commits.

## [0.3.7] — 2026-04-11

### Fixed
- **Tab buttons in the menubar popover** — Settings / History / Errors tabs now respond to clicks anywhere inside the tab frame, not just on the icon or text. Added `.contentShape(Rectangle())` to the tab button label so the whole region is hit-testable.
- **History view layout breakage with many pages** — Replaced the numbered page-button pagination with a compact `< Page X of Y >` control in both History and Errors tabs. The old row of page-number buttons grew wider than the 520px window when there were many pages (e.g., filtering 559 entries to "Last 7 Days"), pushing entry cards off-screen to the left.
- Added a defensive `.frame(maxWidth: 520)` clamp to both `HistoryView` and `ErrorsView` to prevent any future child content from blowing out the popover width.

## [0.3.6] — 2026-04-03

### Added
- **Custom Vocabulary**: New settings section for Deepgram custom vocabulary with enable/disable toggle
  - Keyterm prompting for Nova-3/Flux models — boost recognition of domain-specific words (e.g., Tavily, MCP, Context7)
  - Keywords boosting for Nova-2/Enhanced/Base models — auto-detected based on selected model
  - Add/remove terms with inline UI, persisted across app restarts (JSON-encoded in UserDefaults)
  - Toggle to enable/disable — when off, no vocabulary params sent to Deepgram
  - Safe URL encoding for query parameter values (encodes `:`, `+`, `&`, `=` in term values)

## [0.3.5] — 2026-04-03

### Added
- **History tab**: New "History" tab in the menubar window showing past transcriptions alongside LLM outputs
  - Side-by-side view: Deepgram transcript (left) and LLM response (right) for each recording
  - Time-based filtering: Last 24 Hours, Last 7 Days, Last 30 Days, Last 3 Months (defaults to Last 24 Hours)
  - Pagination with 8 entries per page
  - Per-entry copy buttons for transcript and LLM output
  - Bulk copy buttons: "Copy All Transcripts" and "Copy All LLM Outputs" for all filtered entries
  - Clear All with confirmation dialog
  - History persists across app restarts (stored as JSON in Application Support)
- **Tabbed settings UI**: Settings window now has "Settings" and "History" tabs

## [0.3.4] — 2026-02-17

### Fixed
- **CRITICAL**: Audio engine warmup hangs MainActor for 9+ minutes during device reconfiguration
  - Root cause: `AVAudioEngine()`, `inputNode`, `outputFormat()` are synchronous CoreAudio calls that block the MainActor thread when the audio device graph is mid-reconfiguration
  - Solution: Move engine creation to `Task.detached` via `EngineSetup` wrapper so it runs on the cooperative thread pool; MainActor stays responsive and the 10-second timeout can actually fire
  - Added `@unchecked Sendable` wrapper for safe cross-actor transfer of engine setup

- **HIGH**: Buffer health check too aggressive (250ms fixed wait, single check)
  - Root cause: First buffer sometimes arrives at ~264ms (6ms after the 250ms check declares failure), causing false "engine broken" errors
  - Solution: Replace fixed sleep with active polling loop (50ms intervals, up to 2 seconds); exits immediately when first buffer arrives

- **HIGH**: No overall warmup timeout protection
  - Root cause: Only `engine.start()` had a 5-second timeout; the engine constructor and property accesses were unprotected
  - Solution: Wrap entire `warmUp()` in a 10-second `withThrowingTaskGroup` timeout that races against the warmup task

- **MEDIUM**: Stale `lastBufferTimestamp` causes false health check pass
  - Root cause: Polling loop could see a timestamp from the previous engine instance and falsely believe new buffers are flowing
  - Solution: Reset `lastBufferTimestamp` to nil after `engine.start()` but before polling begins

- **MEDIUM**: Rapid device changes trigger cascading engine restarts
  - Root cause: Multiple `AVAudioEngineConfigurationChange` notifications within seconds each trigger a full restart, stacking on top of each other
  - Solution: Guard in `performEngineRestart()` skips restart if warmup is already in progress

- **MEDIUM**: Cancelled warmup task could resume and modify state
  - Root cause: After timeout fires, orphaned warmup task may resume and install taps or assign engines, conflicting with a new warmup
  - Solution: Added `Task.checkCancellation()` at 3 key points: after engine creation, before tap installation, before engine start

### Added
- **Audio input device identification**: Logs device name and UID during warmup via CoreAudio APIs (`AudioObjectGetPropertyData`)
  - Example: `Audio input device: "MacBook Air Microphone" (UID: BuiltInMicrophoneDevice)`
  - Makes it immediately visible in logs when the wrong device is selected

- **Audio device display in Settings**: Shows current input device name in the Permissions section

- **Format validation warning**: Logs a warning when detected format (44100Hz stereo) may indicate wrong input device

- **Granular timing logs**: Individual timing for engine creation, preparation, start, and buffer polling

---

## [0.3.3] — 2026-02-04 (deployed)

### Fixed
- **CRITICAL**: FileHandle leak in LoggingService that exhausts file descriptors over time
  - Symptoms: "too many open files" crash after extended logging
  - Solution: Use defer block to guarantee closeFile() on all code paths

- **CRITICAL**: Task leak in withTimeout() leaving orphaned async tasks running
  - Symptoms: Background tasks consuming resources, unpredictable behavior on subsequent calls
  - Solution: Proper task cancellation and cleanup in all branches

- **CRITICAL**: Clipboard data loss on task cancellation or paste failure
  - Symptoms: User's clipboard permanently corrupted if app crashes during paste
  - Solution: Use defer block to guarantee clipboard restoration even if task is cancelled

- **HIGH**: Task cancellation race in performEngineRestart() causing nil reference crashes
  - Symptoms: "unexpectedly found nil" crash during device change recovery
  - Solution: Wait 100ms for cancelled task to unwind before tearing down engine

- **HIGH**: State machine lock-in where engine stuck in `.warmingUp` state forever
  - Symptoms: No recordings possible after certain error conditions
  - Solution: Always set final state (running/broken/stopped) regardless of how task ends

- **HIGH**: Nil reference when device change occurs and weak self is deallocated
  - Symptoms: Crash in device change handler during app shutdown
  - Solution: Explicit nil check before accessing self properties

- **HIGH**: Stale buffer timestamp threshold too aggressive for loaded systems
  - Symptoms: False "engine broken" errors on slow machines
  - Solution: Increased threshold from 2s to 5s for heavily loaded systems

- **MEDIUM**: No audio format validation before writing WAV file
  - Symptoms: Silent recording failures with certain audio device formats
  - Solution: Validate sample rate (≤192kHz) and channel count (≤2) before writing

- **MEDIUM**: Deepgram API rate-limit (HTTP 429) not handled
  - Symptoms: Transient rate limit errors fail immediately instead of retrying
  - Solution: Parse Retry-After header and automatically retry once on 429 response

- **MEDIUM**: Temp file accumulation on transcription/LLM errors
  - Symptoms: /tmp fills up with abandoned audio files over time
  - Solution: Clean up temp files in stopAndSend() error paths

- **LOW**: Observable doesn't track UserDefaults changes in AppSettings
  - Symptoms: UI doesn't update when settings change
  - Solution: Documented pattern of using local @State instead of relying on observation

### Added
- **Proactive engine recovery**: App monitors for audio configuration changes and recovers if engine is broken
- **Enhanced error handling**: Deepgram rate-limit retry, format validation, proper cleanup on errors
- Better documentation of timing assumptions and actor isolation patterns

### Improved
- Reliability: 13 bug fixes covering critical resource leaks, race conditions, and error paths
- Robustness: Better handling of edge cases and system under load scenarios
- Debugging: More context in error messages for audio pipeline failures

---

## [0.3.2] — 2026-02-04 (deployed)

### Fixed
- Audio engine warmup race condition causing popup to close immediately
  - Increased wait time from 100ms to 250ms for buffer arrival
  - Track buffer timestamps during warmup (not just during recording)

---

## [0.3.1] — 2026-02-04 (deployed)

### Fixed
- **Hotkey fails to open recording popup**
  - Root cause 1: warmUp() was silently swallowing errors with `try?`, causing silent failures
  - Root cause 2: hotkey handler didn't catch `engineBroken` state, only `engineNotReady`
  - Solution: Changed error propagation to `try` instead of `try?`, added engineBroken handler
  - When engine is broken, now calls `recoverEngine()` for hard reset + retry instead of just warmUp()

### Improved
- Error handling: Failed warmups now properly throw errors to callers
- Recovery UI: Shows when engine enters broken state during recovery attempts
- Hotkey reliability: Now handles both not-ready and broken engine states

---

## [0.3.0] — 2026-02-04 (deployed)

### Fixed
- **Critical**: 76-second audio engine stall during rapid device changes
  - Root cause: Race condition in warmUp() caused concurrent initialization attempts to interfere
  - Audio capture appeared active (level meter moved) but no buffers flowed to file
  - Solution: Atomic state machine with three states (stopped → warmingUp → running) prevents reentrancy

### Added
- **Async/await-based engine warmup** with automatic timeout protection (5 seconds max)
  - Prevents hung `AVAudioEngine.start()` calls from blocking the entire app
  - Provides clear error messages ("Audio engine timeout after 5 seconds")

- **Health validation** via buffer flow monitoring
  - Engine confirms audio buffers are flowing before allowing recording to start
  - Detects broken engine state (no buffers received in >2 seconds)
  - Prevents silent recording failures (mic appears to work, no audio captured)

- **Device change debouncing** (500ms)
  - Eliminates engine restart thrashing during rapid plug/unplug of headphones
  - Only one warmup attempt per 500ms of stable state
  - Improves reliability when users quickly change audio devices

- **Automatic recovery from broken state**
  - Shows UI feedback ("Audio Engine Recovery — Attempting automatic recovery...")
  - Hard resets engine and retries warmup
  - Manual recovery via "Cancel" button if automatic recovery fails

- **Enhanced structured logging**
  - New error levels: `engineStartTimeout`, `engineBroken`, `engineNotReady`
  - Performance metrics: warmup duration, buffer flow timing, state transitions
  - Detailed diagnostics for debugging audio pipeline issues

### Changed
- `warmUp()` is now `async throws` (was `throws`)
- App initialization performs async warmup in background Task
- Hotkey handler gracefully handles `engineNotReady` state with fallback async warmup
- Recording popup shows recovery UI when engine enters broken state

### Improved
- Recording reliability: 100% of recording sessions should now capture audio correctly
- Responsiveness: Async warmup no longer blocks the main thread
- Debuggability: Structured error messages and recovery logs in Console.app

---

## [0.2.0] — 2026-02-02 (deployed)

### Added
- **Cancel hotkey** (Cmd+[): Cancel a recording in progress without sending to transcription
  - Configurable in settings alongside the existing recording hotkey
  - Only active when recording or paused — no-op otherwise
  - Deletes temp audio file and closes popup

### Includes all changes from 0.1.1–0.1.2
- Keep-engine-running audio pattern (instant recording start, ~21ms worst-case)
- Versioning system (MAJOR.DEPLOY.LOCAL) with version display in settings
- Buffer size reduced to 1024, engine warms up at app launch

---

## [0.1.2] — 2026-02-02 (local)

### Fixed
- **Critical**: Previous "reuse stopped engine" approach actually degraded recording start latency (up to 2.5s lost)
  - Root cause: `engine.stop()` tears down the CoreAudio HAL hardware connection entirely — reusing a stopped engine has the same cold-start delay as a fresh engine
  - New approach: keep AVAudioEngine running permanently with a capture flag (`OSAllocatedUnfairLock`)
  - Tap callback discards buffers when not recording (negligible CPU)
  - Recording starts on the next audio callback (~21ms worst-case at 1024 buffer size)

### Changed
- Buffer size reduced from 4096 to 1024 (worst-case first-buffer latency: 85ms → 21ms)
- Engine warms up at app launch (no cold-start on first recording)
- pause/resume now uses capture flag toggle instead of engine.pause()/start()
- Device changes automatically restart the engine

### Trade-off
- macOS microphone indicator (orange dot) visible while app is running

## [0.1.1] — 2026-02-02 (local)

### Fixed
- Audio recording startup delay: first 1-1.5 seconds of speech were lost
  - Recording now starts BEFORE the popup appears (eliminates SwiftUI rendering delay)
  - AVAudioEngine is reused across recordings (eliminates cold-start delay)
  - Engine is invalidated on audio device configuration changes (headphones plug/unplug)

### Changed
- Renamed all VoiceInk references to VoicePolish (files, temp prefixes, docs)
- Updated build.sh to reference correct VoicePolish/Info.plist path

## [0.1.0] — 2026-01-31 (deployed)

### Added
- Initial release of VoicePolish
- Global hotkey (Cmd+]) for voice recording
- Deepgram STT integration with model selection
- OpenRouter LLM processing with custom model support and verification
- Auto-paste into previously focused application
- Configurable temperature and system prompt
- Floating recording popup (non-activating, preserves focus)
- Hotkey toggle: press once to record, again to stop & send
- Microphone and Accessibility permission management
- Logging to ~/Library/Logs/VoicePolish/
