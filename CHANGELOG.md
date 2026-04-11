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
