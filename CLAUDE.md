# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (debug)
swift build

# Build release + create .app bundle (code-signed with Apple Development certificate)
bash build.sh

# Deploy to /Applications (the ONLY install location)
osascript -e 'quit app "VoicePolish"' 2>/dev/null; sleep 1
rm -rf /Applications/VoicePolish.app
cp -R VoicePolish.app /Applications/
rm -rf VoicePolish.app
open /Applications/VoicePolish.app
```

The build script creates `VoicePolish.app` in the project root as a temporary build artifact. **Always deploy to `/Applications/VoicePolish.app`** — do NOT leave the .app in the project directory or run it from there. After copying to /Applications, delete the local .app to avoid duplicates.

The build script code-signs with `Apple Development: achyutasuryatej@icloud.com (4B3CUD9DRZ)`. This stable signing identity is required for macOS TCC (accessibility/microphone) permissions to persist across rebuilds.

There are no tests or linting configured.

## Architecture

VoicePolish is a macOS 14+ menubar-only app (LSUIElement=YES) built with Swift Package Manager. It records voice audio, transcribes via Deepgram STT, processes through any OpenRouter LLM, and auto-pastes the result into the previously focused text field.

### Pipeline Flow

Hotkey (Cmd+]) → auto-start recording → hotkey again (or Stop button) → Deepgram STT → OpenRouter LLM → clipboard + simulated Cmd+V paste → restore clipboard

### Key Components

**AppState** (`VoicePolishApp.swift`) — `@MainActor @Observable` class that owns all services, registers the global hotkey listener, and coordinates the recording popup. Recording starts in `toggleRecordingPopup()` BEFORE showing the popup to eliminate SwiftUI rendering delay. The `shouldStopAndSend` flag bridges hotkey events to the SwiftUI view via `.onChange`.

**RecordingPopupView** (`Views/RecordingPopupView.swift`) — Contains both `RecordingPopupController` (NSPanel management) and the SwiftUI view. The NSPanel uses `.nonActivatingPanel` style mask so it does NOT steal focus from the target text field. The view drives a state machine: recording → transcribing → processing → done/error. The `stopAndSend()` method orchestrates the entire pipeline. Note: the popup opens with recording already in progress (popupState starts as `.recording`).

**Services** — `DeepgramService` and `OpenRouterService` are Swift `actor` types for thread safety. `AudioRecorder` and `TextInsertionService` are `@MainActor`. `LoggingService` is `@unchecked Sendable` with thread-safe file writing. `AudioRecorder` reuses its `AVAudioEngine` instance across recordings (kept stopped but alive) to avoid cold-start delay; the engine is invalidated on audio device configuration changes.

**AppSettings** (`Models/AppSettings.swift`) — Singleton wrapping UserDefaults via computed properties. Note: `@Observable` does not properly track these computed properties, so views that need reactive updates use local `@State` variables (see `LLMModelPickerView.displayedModel`).

### Focus Management

After processing, the app must re-activate the previously focused app before pasting. `RecordingPopupController.previousApp` captures the frontmost app at popup open time. `stopAndSend()` closes the popup, calls `NSApp.deactivate()`, activates the target app, waits 500ms, verifies focus, and retries once if the wrong app got focus.

### Text Insertion

`TextInsertionService` saves the current clipboard, sets the response text, simulates Cmd+V via `CGEvent`, waits 200ms, then restores the original clipboard. Requires Accessibility permission granted to the signed app bundle.

### Permissions

Accessibility permission is tied to the app's code signature in the TCC database. Ad-hoc signing (`codesign --sign -`) breaks permissions on every rebuild. The Apple Development certificate in `build.sh` provides a stable identity.

## Single External Dependency

`KeyboardShortcuts` (sindresorhus, v2+) — global hotkey registration. Hotkey names are defined in `Utilities/HotkeyManager.swift`:
- `.toggleRecording` — defaults to Cmd+] (start/stop recording)
- `.cancelRecording` — defaults to Cmd+[ (cancel recording without sending)

## Versioning

Three-part scheme: **`MAJOR.DEPLOY.LOCAL`** (e.g. `0.2.0`).

- `MAJOR` — breaking changes / major milestones
- `DEPLOY` — incremented on each production push; resets `LOCAL` to `0`
- `LOCAL` — incremented on each local build/test cycle

### Files to update when changing the version

All three must be kept in sync. Update them in this order:

1. **`VERSION`** (project root) — single line, e.g. `0.2.0`. Source of truth.
2. **`VoicePolish/Utilities/AppVersion.swift`** — change the `appVersion` string constant (displayed in the settings UI).
3. **`VoicePolish/Info.plist`** — update `CFBundleShortVersionString` to the new version, and increment `CFBundleVersion` (integer build number) by 1.
4. **`CHANGELOG.md`** — add a new entry under the version heading describing what changed.

### Example: bumping from 0.2.0 to 0.2.1

```
VERSION:            0.2.0 → 0.2.1
AppVersion.swift:   let appVersion = "0.2.1"
Info.plist:         CFBundleShortVersionString: "0.2.1", CFBundleVersion: "5"
CHANGELOG.md:       Add ## [0.2.1] section
```

After updating, rebuild and deploy to /Applications (see Build & Run above).

## Logging

Logs written to `~/Library/Logs/VoicePolish/voicepolish-YYYY-MM-DD.log` and OSLog subsystem `com.voicepolish.app`. Check logs for debugging pipeline issues (API responses, focus transfer, clipboard operations).
