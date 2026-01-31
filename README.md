# VoicePolish - AI-Powered Voice-to-Text Refiner for macOS

> **Open Source** | Record your voice, transcribe with AI, and auto-paste refined text into any app

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What is VoicePolish?

VoicePolish is a lightweight macOS menubar application that transforms raw voice recordings into polished, refined text. Simply press your hotkey, speak naturally, and the app automatically transcribes and refines your speech using AI before pasting it into your active application.

### Features

🎤 **Voice Recording** - Global hotkey activation (Cmd+]) for quick recording
🧠 **AI Transcription** - Uses Deepgram's advanced speech-to-text engine
✨ **LLM Refinement** - Cleans up transcription with OpenRouter-powered AI models
📋 **Auto-Paste** - Automatically pastes refined text into any application
⚙️ **Customizable** - Configure temperature, model selection, and system prompts
🔧 **Privacy-Focused** - All processing respects your configured API keys

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Swift 5.9+**
- **API Keys** (free tiers available):
  - [Deepgram](https://console.deepgram.com/) - Speech-to-text
  - [OpenRouter](https://openrouter.ai/) - LLM processing

## Installation

### Option 1: Build from Source

```bash
# Clone the repository
git clone https://github.com/achyutasurya/VoicePolish---AI-Powered-Voice-to-Text-Refiner-macOS-.git
cd VoicePolish---AI-Powered-Voice-to-Text-Refiner-macOS-

# Build the release app
bash build.sh

# Run the app
open VoicePolish.app
```

### Option 2: Using Swift Package Manager

```bash
swift build -c release
```

## Quick Start

1. **Get API Keys**
   - Sign up for [Deepgram](https://console.deepgram.com/) (free tier: 12,000 minutes/month)
   - Sign up for [OpenRouter](https://openrouter.ai/) (pay-as-you-go or free tier)

2. **Launch VoicePolish**
   - Open `VoicePolish.app`
   - Click the microphone icon in your menubar

3. **Configure Settings**
   - Enter your Deepgram API key
   - Enter your OpenRouter API key
   - Select your preferred LLM model (Mistral Nemo recommended for speed/cost)
   - Set temperature (0.0 = deterministic, 1.0+ = creative)

4. **Grant Permissions**
   - Allow Microphone access
   - Allow Accessibility (required for auto-paste)

5. **Start Using**
   - Press `Cmd+]` to start recording
   - Press `Cmd+]` again to stop and process
   - Text auto-pastes into your active app!

## Configuration

### Available LLM Models

- **Mistral Nemo** (Recommended) - $0.02/1M input tokens, ~34 tokens/sec
- Claude 3 Haiku - $0.25/1M input tokens, fastest response
- Claude Sonnet 4 - High quality
- GPT-4o - OpenAI's latest
- Gemini 2.5 Flash - Google's fast model
- Llama 3.3 70B - Open source option
- DeepSeek Chat - Cost-effective

### Temperature Settings

- **0.0 - 0.3**: Deterministic (recommended for cleanup tasks)
- **0.3 - 0.7**: Balanced (consistent with minor variation)
- **0.7 - 1.0**: Creative (more varied output)
- **1.0+**: Very Creative (slower with reasoning models)

### Custom System Prompt

Customize how the LLM processes your transcriptions. Default prompt focuses on grammar, punctuation, and filler word removal while preserving meaning.

## Architecture

```
Hotkey (Cmd+])
  ↓
Record Audio (Deepgram)
  ↓
Transcribe (Deepgram STT)
  ↓
Process with LLM (OpenRouter)
  ↓
Copy to Clipboard
  ↓
Paste (Cmd+V) → Target App
  ↓
Restore Original Clipboard
```

## Logging

Logs are written to:
```
~/Library/Logs/VoicePolish/voicepolish-YYYY-MM-DD.log
```

View logs for debugging API issues, focus problems, or transcription errors.

## Development

### Project Structure

```
VoicePolish/
├── VoiceInk/                    # Main app source
│   ├── VoicePolishApp.swift     # App entry point
│   ├── Models/                  # Data models
│   │   ├── AppSettings.swift    # User settings
│   │   └── LLMModels.swift      # Available models
│   ├── Services/                # Business logic
│   │   ├── DeepgramService.swift
│   │   ├── OpenRouterService.swift
│   │   ├── AudioRecorder.swift
│   │   ├── TextInsertionService.swift
│   │   └── LoggingService.swift
│   ├── Views/                   # SwiftUI interfaces
│   │   ├── RecordingPopupView.swift
│   │   ├── SettingsView.swift
│   │   └── APIKeyView.swift
│   ├── Utilities/               # Helpers
│   │   ├── HotkeyManager.swift
│   │   └── PermissionManager.swift
│   └── Info.plist               # App configuration
├── Package.swift                # SPM manifest
├── build.sh                     # Release build script
├── LICENSE                      # MIT License
├── README.md                    # This file
├── CLAUDE.md                    # Development notes
└── .gitignore                   # Git exclusions
```

### Dependencies

- **KeyboardShortcuts** (v1.15.0) - Global hotkey registration

### Building

```bash
# Debug build
swift build

# Release build (creates signed .app)
bash build.sh
```

## Troubleshooting

### App Won't Paste Text
- Check if Accessibility permission is granted (Settings → Accessibility)
- Ensure target app accepts keyboard input
- Check logs: `tail -f ~/Library/Logs/VoicePolish/voicepolish-*.log`

### Transcription Failing
- Verify Deepgram API key is valid
- Check microphone permissions
- Ensure internet connection is stable

### Processing Taking Too Long
- High temperature settings increase processing time
- Reasoning models (Olmo) are slower - try Mistral Nemo instead
- Check OpenRouter API status

### API Key Not Being Saved
- Clear app cache: `rm ~/Library/Preferences/com.voicepolish.app*`
- Re-enter API keys in settings

## Contributing

Contributions are welcome! Please feel free to submit Pull Requests for bug fixes, features, or improvements.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Deepgram](https://deepgram.com/) - Speech-to-text engine
- [OpenRouter](https://openrouter.ai/) - LLM API aggregator
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - Global hotkey support

## Disclaimer

This is a personal project. Use at your own risk. Remember to:
- Keep your API keys secure
- Monitor your API usage and costs
- Respect rate limits of third-party services

---

**Questions or Issues?** Please open an issue on GitHub.

Happy voice polishing! 🎤✨
