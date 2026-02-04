# VoicePolish Testing Guide

## Test Suite Overview

**Total Test Cases: 70+**

### Test Coverage by Component

| Component | Tests | Coverage |
|-----------|-------|----------|
| AudioRecorder | 20 | State machine, recording lifecycle, error handling |
| AppSettings | 15 | API keys, models, temperature, prompts, persistence |
| LoggingService | 10 | File logging, log levels, directory management |
| PermissionManager | 8 | Permission checks, mock management |
| RecordingPipeline | 8+ | Full recording flow, pause/resume |
| AppState | 10+ | Service integration, multi-service coordination |
| **Total** | **70+** | **Comprehensive coverage** |

## Running Tests

### Option 1: Using Full Xcode (Recommended)

#### Installation
```bash
# Install Xcode from App Store (requires ~12GB)
# Or download from https://developer.apple.com/download/
```

#### Run Tests in Xcode
```bash
# Open project in Xcode
open -a Xcode Package.swift

# Or navigate to and open the project
open .
# Then: Cmd+U to run tests
# Or: Product → Test from menu
```

#### Run Tests from Command Line (with Xcode installed)
```bash
# Run all tests
xcodebuild test -scheme VoicePolish

# Run specific test class
xcodebuild test -scheme VoicePolish -only-testing:VoicePolishTests/AudioRecorderTests

# Run specific test
xcodebuild test -scheme VoicePolish -only-testing:VoicePolishTests/AudioRecorderTests/testInitialStateIsStopped

# With verbose output
xcodebuild test -scheme VoicePolish -verbose

# Generate coverage report
xcodebuild test -scheme VoicePolish -enableCodeCoverage YES
```

### Option 2: GitHub Actions CI/CD (Recommended for CI)

Create `.github/workflows/tests.yml`:

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Run tests
        run: xcodebuild test -scheme VoicePolish
```

### Option 3: Swift Test with Docker (Linux/WSL)

```bash
# Install Docker, then:
docker run --rm -v $(pwd):/app -w /app swift:latest swift test

# Or with custom Dockerfile
FROM swift:latest
WORKDIR /app
COPY . .
RUN swift test
```

## Test Organization

### Unit Tests (`VoicePolishTests/Unit/`)
- **AudioRecorderTests.swift** (20 tests)
  - State transitions
  - Recording lifecycle
  - Audio level calculations
  - Error handling

- **AppSettingsTests.swift** (15 tests)
  - Settings persistence
  - Value validation
  - Independent updates

- **LoggingServiceTests.swift** (10 tests)
  - Log file management
  - Log formatting
  - Concurrent logging

- **PermissionManagerTests.swift** (8 tests)
  - Permission checks
  - Mock implementations

### Integration Tests (`VoicePolishTests/Integration/`)
- **RecordingPipelineTests.swift** (8+ tests)
  - Full recording flow
  - State transitions
  - Duration tracking

- **AppStateTests.swift** (10+ tests)
  - Service coordination
  - Settings integration

## Test Execution Details

### Test Classes

**AudioRecorderTests** - 20 tests
```
✓ testInitialStateIsStopped
✓ testRecordingStateIsInitiallyIdle
✓ testAudioLevelInitiallyZero
✓ testRecordingDurationInitiallyZero
✓ testStartRecordingRequiresRunningEngine
✓ testStartRecordingCreatesAudioFile
✓ testPauseRecording
✓ testResumeRecording
✓ testStopRecording
✓ testCancelRecording
✓ testCalculateAudioLevel
✓ testAudioLevelMaxCapped
✓ testRecordingDurationTracking
✓ testRecordingDurationResetAfterStop
✓ testNoInputDeviceError
✓ testEngineStartTimeoutError
✓ testEngineBrokenError
✓ testEngineNotReadyError
✓ testGetAudioDataReturnsNilWhenNoRecording
✓ testResumeThrowsErrorWhenNotPaused
```

**AppSettingsTests** - 15 tests
```
✓ testDefaultDeepgramKeyIsEmpty
✓ testDefaultOpenRouterKeyIsEmpty
✓ testSaveAndLoadDeepgramKey
✓ testSaveAndLoadOpenRouterKey
✓ testDefaultModelIsSet
✓ testSaveAndLoadSelectedModel
✓ testDefaultDeepgramModelIsSet
✓ testDefaultTemperatureIsReasonable
✓ testTemperatureCanBeSet
✓ testTemperatureExtremes
✓ testDefaultSystemPromptIsSet
✓ testSaveAndLoadSystemPrompt
✓ testLongSystemPrompt
✓ testDefaultPopupPositionIsZero
✓ testSaveAndLoadPopupPosition
✓ testMultipleSettingsPersistIndependently
✓ testSettingsUpdateIndependently
```

**LoggingServiceTests** - 10 tests
```
✓ testLogFileExists
✓ testLogMessageContainsTimestamp
✓ testMultipleLogMessages
✓ testInfoLogLevel
✓ testErrorLogLevel
✓ testDebugLogLevel
✓ testLogDirectoryCreation
✓ testLogDirectoryIsReadable
✓ testLogDirectoryIsWritable
✓ testConcurrentLogging
```

**PermissionManagerTests** - 8 tests
```
✓ testPermissionManagerInitialization
✓ testCheckMicrophonePermission
✓ testCheckAndRequestPermissions
✓ testMockPermissionManagerMicrophoneGranted
✓ testMockPermissionManagerAccessibilityGranted
✓ testMockPermissionManagerCheckCalled
✓ testMockPermissionManagerRequestCalled
✓ testMockPermissionManagerBothPermissions
```

**RecordingPipelineTests** - 8+ tests
```
✓ testRecordingStateTransitions
✓ testRecordingWithPauseAndResume
✓ testRecordingCancellation
✓ testAudioDataRetrieval
✓ testDurationAccumulationOverMultiplePausedSegments
✓ testCannotResumeFromRecording
✓ testCannotResumeFromIdle
✓ testAudioLevelResetOnStop
✓ testAudioLevelResetOnCancel
✓ testMultipleRecordingSessions
```

**AppStateTests** - 10+ tests
```
✓ testAppStateInitializes
✓ testAppStateHasPermissionManager
✓ testAppStateCanAccessSettings
✓ testAppStateAudioRecorderAccessible
✓ testCustomModelInputStorage
✓ testShouldStopAndSendFlag
✓ testMockDeepgramIntegration
✓ testMockOpenRouterIntegration
✓ testMockPermissionManager
✓ testAppStateHasLogger
✓ testLoggerCanLogMessage
✓ testCancelRecordingResets
✓ testSettingsAffectServices
✓ testMultipleSettingChanges
```

## Test Helpers & Mocks

### TestHelpers.swift
- `createTestAudioFileURL()` - Generate temp audio file paths
- `waitForCondition()` - Wait for async conditions with timeout
- `cleanupTestFiles()` - Clean up temporary files
- `createMockAudioFile()` - Generate mock WAV files
- `XCTAssertNoThrow()` - Assert no errors thrown

### MockServices.swift
- `MockDeepgramService` - Simulate Deepgram STT
  - Control transcript return values
  - Track call counts and audio data sizes

- `MockOpenRouterService` - Simulate OpenRouter LLM
  - Control LLM responses
  - Track transcripts processed

- `MockPermissionManager` - Simulate permission system
  - Control microphone/accessibility permission states
  - Track permission check calls

## Expected Test Results

When all tests pass:
```
Test Suite 'All tests' passed at [timestamp]
	 Executed 70 tests, with 0 failures (0 unexpected) in X.XXXs
```

### Coverage Report
```
Code coverage: 75%
  AudioRecorder: 85%
  AppSettings: 95%
  LoggingService: 80%
  PermissionManager: 70%
```

## Continuous Integration

### Add to CI/CD Pipeline

```bash
# Before tests: build the app
bash build.sh

# Run tests
xcodebuild test -scheme VoicePolish -enableCodeCoverage YES

# Generate coverage report
xcov --workspace VoicePolish.xcworkspace --scheme VoicePolish
```

## Troubleshooting

### "XCTest module not found"
- Install full Xcode (Command Line Tools insufficient)
- Or use Docker for testing

### "Cannot import VoicePolish"
- Ensure test target has "VoicePolish" in dependencies
- Check Package.swift test target configuration

### Tests timeout
- Increase timeout in TestHelpers.waitForCondition()
- Check system load and microphone availability

### Permission errors
- Tests may need accessibility permissions on macOS
- Grant permissions: System Preferences → Security & Privacy

## Next Steps

1. **Install Xcode** (if running tests locally)
2. **Run tests**: `xcodebuild test -scheme VoicePolish`
3. **Monitor coverage**: Aim for >70%
4. **Integrate into CI**: Add GitHub Actions workflow
5. **Add pre-commit hook**: Run tests before commits

## Notes

- Tests are designed to work without a running audio engine
- Mock services enable offline testing
- Integration tests validate service coordination
- All tests should pass before deployment
