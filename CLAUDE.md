# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Open in Xcode
open TypeWhisper.xcodeproj

# Release build (command line)
xcodebuild build -project TypeWhisper.xcodeproj -scheme TypeWhisper -configuration Release

# Run tests (App)
xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Run tests (Plugin SDK)
swift test --package-path TypeWhisperPluginSDK
```

Requirements: Xcode 16+, macOS 14.0+.

## Architecture Overview

### Entry Point
- `TypeWhisper/App/main.swift` — overrides `Bundle.main` for in-app language switching, then calls `TypeWhisperApp.main()`
- `TypeWhisperApp.swift` — `MenuBarExtra` + `Settings` + `History` + `ErrorLog` windows

### Dependency Injection
`ServiceContainer.shared` is the central DI container — a singleton that initializes all services. ViewModels use a static `_shared` pattern for singleton access.

### Service Layer (key services)
| Service | Responsibility |
|---------|----------------|
| `ModelManagerService` | Selects and runs transcription engine (delegates to plugins) |
| `AudioRecordingService` / `AudioRecorderService` | Mic recording |
| `HotkeyService` | Global hotkey registration (single-modifier keys supported) |
| `TextInsertionService` | Clipboard + Cmd+V text insertion |
| `HistoryService` | SwiftData-based transcription history |
| `PromptProcessingService` | LLM prompt orchestration and execution |
| `PluginManager` | Plugin discovery and lifecycle |
| `HTTPServer` | Local REST API on port 8978 |
| `EventBus` | Typed pub/sub (events: `recordingStarted`, `transcriptionCompleted`, `textInserted`, etc.) |
| `ProfileService` | Per-app/URL profile matching and persistence |

### Plugin System
- 5 plugin types: `TranscriptionEnginePlugin`, `LLMProviderPlugin`, `PostProcessorPlugin`, `ActionPlugin`, `TypeWhisperPlugin`
- Plugins are `.bundle` files in `~/Library/Application Support/TypeWhisper/Plugins/`
- Built-in plugins in `Plugins/` directory serve as reference implementations (WhisperKit, Parakeet, SpeechAnalyzer, Qwen3, Voxtral, Groq, OpenAI, Gemini, Linear, Webhook)
- Plugin SDK at `TypeWhisperPluginSDK/` is a Swift Package for third-party plugin development

### HTTP API (port 8978)
- `POST /v1/transcribe` — transcribe audio files
- `GET /v1/status` — server status
- `GET /v1/models` — list available models
- `GET /v1/history` — search transcription history
- `PUT /v1/profiles/toggle` — toggle profile
- `POST /v1/dictation/start|stop` — dictation control
- Bound to `127.0.0.1` only, disabled by default

### Data Models (SwiftData)
- `Profile` — per-app/URL transcription settings
- `PromptAction` — custom LLM prompt configurations
- `TranscriptionRecord` — historical transcription entries
- `Snippet` — text expansion with placeholders (`{{DATE}}`, `{{TIME}}`, `{{CLIPBOARD}}`)
- `DictionaryEntry` / `TermPack` — custom terminology and term packages

## Key Conventions

### Concurrency
Swift 6 strict concurrency enabled throughout. UI-related services and ViewModels are `@MainActor`. Data crossing actor boundaries must be `Sendable`.

### Localization
All user-facing strings use `String(localized:)`. The `main.swift` override enables in-app language switching without macOS system restart. Translations managed in `Localizable.xcstrings`.

### Profile Matching Priority
1. App + URL (exact, e.g. Chrome + github.com)
2. URL only (cross-browser, e.g. any browser + github.com)
3. App only (e.g. entire Chrome)

### Build Configurations
- `DEBUG` vs `Release`
- `APPSTORE` preprocessor flag for App Store vs direct distribution
- Dev builds use separate App Support directory (`TypeWhisper-Dev`) and Keychain prefix to avoid conflicts

### Debug vs Release Paths
Dev builds write to `~/Library/Application Support/TypeWhisper-Dev/`; Release builds use `TypeWhisper/`.

## Directory Structure

```
TypeWhisper/              # Main app source
├── App/                  # Entry point, ServiceContainer, constants
├── Models/               # SwiftData models (Profile, PromptAction, TranscriptionRecord, etc.)
├── Services/             # All business logic services
│   ├── Cloud/            # KeychainService, WavEncoder
│   ├── LLM/              # Apple Intelligence Provider
│   └── HTTPServer/       # REST API server
├── ViewModels/           # MVVM ViewModels
├── Views/                # SwiftUI views
└── Resources/            # Info.plist, entitlements, Localizable.xcstrings, sounds
Plugins/                  # Built-in plugins
TypeWhisperPluginSDK/    # Plugin development SDK (Swift Package)
TypeWhisperWidgetExtension/  # WidgetKit widgets
typewhisper-cli/         # CLI tool
TypeWhisperTests/        # Test suite
```
