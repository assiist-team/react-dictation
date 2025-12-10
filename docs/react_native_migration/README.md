# React Native Dictation Module Migration Plan

This directory contains phased implementation documentation for converting the Flutter Dictation Plugin into a React Native Native Module.

## Overview

The Flutter plugin provides low-latency, native-backed dictation with:
- Streaming speech recognition (partial + final transcripts)
- Real-time waveform visualization at 30 FPS
- Audio preservation in canonical `.m4a` format (AAC-LC, mono, 44.1kHz, 64kbps)
- Audio normalization for imported files
- Duration guardrails (60-minute limit)
- Pre-warmed audio engine for instant mic activation
- Robust permission handling

## Target Architecture

```
React Native App
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  TypeScript Layer                                               │
│  ┌─────────────────────┐   ┌─────────────────────────────────┐  │
│  │ NativeDictationService │ │ WaveformController (useState)  │  │
│  │ - initialize()         │ │ - levels[]                     │  │
│  │ - startListening()     │ │ - updateLevel()                │  │
│  │ - stopListening()      │ │ - reset()                      │  │
│  │ - cancelListening()    │ └─────────────────────────────────┘  │
│  │ - normalizeAudio()     │                                     │
│  └──────────┬──────────────┘                                    │
│             │ NativeModules / TurboModules                      │
└─────────────┼───────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Native Bridge (iOS Swift / Android Kotlin)                     │
│  ┌─────────────────────┐   ┌──────────────────────────────────┐ │
│  │ DictationModule     │   │ Event Emitters                   │ │
│  │ (RCTEventEmitter)   │   │ - onResult                       │ │
│  │                     │   │ - onStatus                       │ │
│  │ Method exports:     │   │ - onAudioLevel                   │ │
│  │ - initialize        │   │ - onAudioFile                    │ │
│  │ - startListening    │   │ - onError                        │ │
│  │ - stopListening     │   │                                  │ │
│  │ - cancelListening   │   │                                  │ │
│  │ - getAudioLevel     │   │                                  │ │
│  │ - normalizeAudio    │   │                                  │ │
│  └──────────┬──────────┘   └──────────────────────────────────┘ │
│             │                                                   │
│             ▼                                                   │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Shared Native Managers (Portable from Flutter)              ││
│  │ - AudioEngineManager.swift   (AVAudioEngine, session)       ││
│  │ - SpeechRecognizerManager.swift (SFSpeechRecognizer)        ││
│  │ - AudioEncoderManager.swift  (AAC encoding)                 ││
│  │ - CanonicalAudioStorage.swift (file paths)                  ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Document Index

| Phase | Document | Description |
|-------|----------|-------------|
| 0 | [00_PROJECT_SETUP.md](./00_PROJECT_SETUP.md) | React Native module scaffolding and project structure |
| 1 | [01_NATIVE_MODULE_BRIDGE.md](./01_NATIVE_MODULE_BRIDGE.md) | iOS Native Module setup with RCTEventEmitter |
| 2 | [02_AUDIO_ENGINE_MIGRATION.md](./02_AUDIO_ENGINE_MIGRATION.md) | Migrate AudioEngineManager with minimal changes |
| 3 | [03_SPEECH_RECOGNIZER_MIGRATION.md](./03_SPEECH_RECOGNIZER_MIGRATION.md) | Migrate SpeechRecognizerManager |
| 4 | [04_AUDIO_ENCODING_MIGRATION.md](./04_AUDIO_ENCODING_MIGRATION.md) | Migrate audio encoding pipeline |
| 5 | [05_DICTATION_COORDINATOR.md](./05_DICTATION_COORDINATOR.md) | Create DictationCoordinator (replaces DictationManager) |
| 6 | [06_TYPESCRIPT_SERVICE_LAYER.md](./06_TYPESCRIPT_SERVICE_LAYER.md) | TypeScript service and React hooks |
| 7 | [07_WAVEFORM_COMPONENTS.md](./07_WAVEFORM_COMPONENTS.md) | React Native waveform visualization |
| 8 | [08_ANDROID_IMPLEMENTATION.md](./08_ANDROID_IMPLEMENTATION.md) | Android native module (Kotlin) |
| 9 | [09_TESTING_AND_VALIDATION.md](./09_TESTING_AND_VALIDATION.md) | Testing strategy and validation |
| 10 | [10_NODEJS_BACKEND_INTEGRATION.md](./10_NODEJS_BACKEND_INTEGRATION.md) | Node.js backend integration patterns |
| 11 | [11_FLUTTER_CLEANUP.md](./11_FLUTTER_CLEANUP.md) | Remove Flutter-specific code and files |

## Key Migration Decisions

### 1. Native Code Reuse
The Swift managers (`AudioEngineManager`, `SpeechRecognizerManager`, `AudioEncoderManager`) are framework-agnostic and can be reused with minimal changes. Only the bridge layer needs replacement.

### 2. Event Communication
| Flutter | React Native |
|---------|--------------|
| `EventChannel` | `RCTEventEmitter` |
| `MethodChannel` | `@objc func` exports |
| `FlutterResult` | Promise callbacks |

### 3. State Management
| Flutter | React Native |
|---------|--------------|
| `ChangeNotifier` | React `useState` / Zustand / Redux |
| `StreamSubscription` | `NativeEventEmitter` listeners |

### 4. UI Components
| Flutter | React Native |
|---------|--------------|
| `CustomPainter` | `react-native-svg` or Canvas |
| `CupertinoButton` | Custom Pressable components |

## Prerequisites

- React Native 0.72+ (or Expo SDK 50+)
- iOS 13.0+ (SFSpeechRecognizer on-device requirement)
- Android API 23+ (for Android speech recognition)
- Xcode 15+
- Node.js 18+ (for backend)

## Estimated Timeline

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| 0 - Project Setup | 0.5 days | None |
| 1 - Native Bridge | 1 day | Phase 0 |
| 2 - Audio Engine | 1 day | Phase 1 |
| 3 - Speech Recognizer | 1 day | Phase 2 |
| 4 - Audio Encoding | 1 day | Phase 2 |
| 5 - Coordinator | 1 day | Phases 2-4 |
| 6 - TypeScript Layer | 1 day | Phase 5 |
| 7 - Waveform UI | 1 day | Phase 6 |
| 8 - Android | 2-3 days | Phase 5 |
| 9 - Testing | 1-2 days | All phases |
| 10 - Backend | 0.5 days | Phase 6 |
| 11 - Flutter Cleanup | 0.5-1 hour | Phases 1-10 complete |

**Total: ~11-13 days + cleanup**

## Quick Start

1. Read [00_PROJECT_SETUP.md](./00_PROJECT_SETUP.md) to scaffold the module
2. Follow phases 1-5 for iOS native implementation
3. Implement TypeScript layer (phase 6-7)
4. Add Android support (phase 8)
5. Validate with testing (phase 9)
6. Integrate with Node.js backend (phase 10)
7. Clean up Flutter code (phase 11)
