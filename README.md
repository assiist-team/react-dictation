# React Native Dictation Module

Low-latency, native-backed dictation for React Native with real-time waveform streaming. Supports both iOS and Android platforms.

## Status Snapshot
- **Primary Platform**: React Native (iOS + Android)
- **iOS**: Native implementation using `AVAudioEngine` + `SFSpeechRecognizer` with <100 ms latency target
- **Android**: Native implementation using `AudioRecord` + `SpeechRecognizer` (Kotlin)
- Implementation documentation and troubleshooting guides live in `docs/react_native_migration/`

## Feature Highlights
- 🎤 **Streaming speech recognition** with partial + final transcripts
- 📊 **Real-time waveform visualization** at 30 FPS
- 💾 **Audio preservation** in canonical `.m4a` format (AAC-LC, mono, 44.1kHz, 64kbps)
- 🔄 **Audio normalization** for imported files
- ⏱️ **Duration guardrails** (60-minute limit)
- ⚡ **Pre-warmed audio engine** for instant mic activation
- 🔐 **Robust permission handling** for microphone and speech recognition
- 📱 **Cross-platform** support for iOS and Android

## Quick Start

### Installation

```bash
npm install react-native-dictation
# or
yarn add react-native-dictation
```

### Basic Usage

```typescript
import { useDictation, Waveform } from 'react-native-dictation';

function MyComponent() {
  const { isListening, startListening, stopListening } = useDictation({
    onResult: (result) => {
      console.log('Transcript:', result.text);
    },
  });

  return (
    <View>
      <Waveform isListening={isListening} />
      <Button 
        title={isListening ? "Stop" : "Start"} 
        onPress={isListening ? stopListening : startListening} 
      />
    </View>
  );
}
```


## System Architecture

```
React Native App
      │
      ▼
┌─────────────────────────────────────────────────────────────────┐
│  TypeScript Layer                                               │
│  ┌─────────────────────┐   ┌─────────────────────────────────┐  │
│  │ DictationService     │   │ WaveformController (useState)  │  │
│  │ - initialize()       │   │ - levels[]                     │  │
│  │ - startListening()   │   │ - updateLevel()                │  │
│  │ - stopListening()    │   │ - reset()                      │  │
│  │ - cancelListening()  │   └─────────────────────────────────┘  │
│  │ - normalizeAudio()   │                                     │
│  └──────────┬───────────┘                                    │
│             │ NativeModules                                    │
└─────────────┼───────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Native Bridge (iOS Swift / Android Kotlin)                    │
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
│  │ Native Managers                                               ││
│  │ iOS:                                                          ││
│  │ - AudioEngineManager.swift   (AVAudioEngine)                 ││
│  │ - SpeechRecognizerManager.swift (SFSpeechRecognizer)        ││
│  │ - AudioEncoderManager.swift  (AAC encoding)                  ││
│  │                                                               ││
│  │ Android:                                                      ││
│  │ - AudioEngineManager.kt      (AudioRecord)                  ││
│  │ - DictationCoordinator.kt   (SpeechRecognizer)             ││
│  │ - AudioEncoderManager.kt     (MediaCodec AAC)               ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Runtime Flow
1. React Native app calls `DictationService.initialize()` to pre-warm the native audio engine and speech recognizer.
2. `initialize()` triggers native pre-warm and returns once both iOS/Android managers report ready.
3. `startListening()` sets up event listeners, then invokes the native module method.
4. Native module (iOS Swift / Android Kotlin) requests microphone permission, starts the audio engine, shares buffers with the speech recognizer, and begins waveform streaming.
5. Native emits `onResult`, `onStatus`, `onAudioLevel`, or `onError` events. TypeScript service surfaces them to React components and the waveform controller.
6. `stopListening()` finalizes the recognition request; `cancelListening()` drops audio immediately. Event listeners are cleaned up automatically.

## API Overview

### Native Module Methods

| Method            | Args | Returns | Description |
|-------------------|------|---------|-------------|
| `initialize`      | —    | `Promise<void>` | Pre-warm audio engine + speech recognizer |
| `startListening`  | `options?: DictationSessionOptions` | `Promise<void>` | Start listening with optional audio preservation |
| `stopListening`   | —    | `Promise<void>` | Stop and finalize recognition |
| `cancelListening` | —    | `Promise<void>` | Cancel without finalizing |
| `getAudioLevel`   | —    | `Promise<number>` | Get current audio level (0-1) |
| `normalizeAudio`  | `sourcePath: string` | `Promise<NormalizedAudioResult>` | Normalize audio file to canonical format |

### Events

| Event        | Payload | Description |
|--------------|---------|-------------|
| `onResult`   | `{ text: string, isFinal: boolean }` | Partial + final transcripts |
| `onStatus`   | `{ status: string }` | Status updates (ready, listening, stopped, etc.) |
| `onAudioLevel` | `{ level: number }` | Audio level updates at 30 FPS |
| `onAudioFile` | `{ path, durationMs, fileSizeBytes, sampleRate, channelCount, wasCancelled }` | Audio file saved (when preservation enabled) |
| `onError`    | `{ message: string, code?: string }` | Error events |


## React Native API

### `DictationService`
Main service class for managing dictation sessions.

- `initialize(): Promise<void>` - Pre-warm audio engine and speech recognizer
- `startListening(options?): Promise<void>` - Start listening with callbacks
- `stopListening(): Promise<void>` - Stop and finalize
- `cancelListening(): Promise<void>` - Cancel without finalizing
- `getAudioLevel(): Promise<number>` - Get current audio level (0-1)
- `normalizeAudio(sourcePath): Promise<NormalizedAudioResult>` - Normalize audio file

### `useDictation` Hook
React hook that wraps `DictationService` with state management.

Returns: `{ isListening, status, audioLevel, startListening, stopListening, cancelListening, initialize }`

### Components
- `Waveform` - Real-time waveform visualization component
- `AudioControlsDecorator` - Convenience wrapper with controls and waveform


## Platform Support

### iOS
- **Minimum Version**: iOS 13.0+
- **Offline Support**: Available when offline dictation packs are installed (Settings → General → Keyboard → Dictation Languages)
- **Permissions**: Microphone + Speech Recognition

### Android
- **Minimum Version**: API 21+ (Android 5.0)
- **Speech Recognition**: Uses Android `SpeechRecognizer` (typically requires Google Play Services)
- **Permissions**: Microphone (speech recognition handled by system)

## Installation & Setup

### iOS Setup
1. Install CocoaPods dependencies: `cd ios && pod install`
2. Add permissions to `Info.plist`:
   - `NSMicrophoneUsageDescription`
   - `NSSpeechRecognitionUsageDescription`

### Android Setup
1. Register `DictationPackage` in `MainApplication.java`/`MainApplication.kt`
2. Permissions are automatically declared in the library's manifest


## Native Implementation Details

### iOS (Swift)
- **`AudioEngineManager.swift`**: Configures `AVAudioSession` (record + measurement mode, 5 ms buffer, 16 kHz sample rate), requests mic permission, installs tap for waveform + recognition, smooths RMS/peak values, streams audio levels at 30 FPS.
- **`SpeechRecognizerManager.swift`**: Manages `SFSpeechRecognizer`, tracks authorization, receives shared buffers, emits partial/final transcripts, maps Speech framework error codes.
- **`DictationCoordinator.swift`**: Core coordinator for React Native bridge calls, state machine, error mapping, event fan-out.

### Android (Kotlin)
- **`AudioEngineManager.kt`**: Uses `AudioRecord` for audio capture, calculates audio levels, manages recording thread.
- **`DictationCoordinator.kt`**: Orchestrates `SpeechRecognizer` and audio recording, handles recognition callbacks.
- **`AudioEncoderManager.kt`**: Encodes audio to AAC/M4A format using `MediaCodec`.

See migration documentation in `docs/react_native_migration/` for implementation details.

## Waveform & Audio Level Streaming
- **iOS**: Single audio tap feeds both waveform smoothing and speech recognizer (AVAudioEngine limitation).
- **Android**: AudioRecord buffers are processed for both waveform visualization and speech recognition.
- Levels are normalized to `0–1` using blended RMS + peak + decibel shaping for consistent visualization.
- Audio levels stream at 30 FPS via `onAudioLevel` events.

## Audio Preservation
- Enable audio preservation via `preserveAudio: true` in `startListening()` options.
- Receive saved audio files via `onAudioFile` callback with metadata (path, duration, size, sample rate, channels).
- **iOS**: Recordings stored in app's Documents directory, default format `.m4a` (AAC-LC, 44.1 kHz, mono, 64 kbps).
- **Android**: Recordings stored in app's files directory, format `.m4a` (AAC-LC, 44.1 kHz, mono, 64 kbps).
- Control file retention on cancel via `deleteAudioIfCancelled` option (default: `true`).
- Files are pre-encoded to AAC, ready for upload without additional processing.

## Permissions

### iOS
Add to `ios/YourApp/Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>We need access to your microphone for low-latency dictation.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>We need speech recognition to convert your voice into text.</string>
```

### Android
Permissions are automatically declared in the library's `AndroidManifest.xml`. No additional configuration needed.

## Project Structure
```
react-native-dictation/
├── react-native/                   # React Native package
│   ├── src/                        # TypeScript source
│   │   ├── DictationService.ts     # Main service class
│   │   ├── hooks/                  # React hooks (useDictation, useWaveform)
│   │   ├── components/             # React components (Waveform, AudioControlsDecorator)
│   │   └── types/                  # TypeScript type definitions
│   ├── ios/                        # iOS native implementation (Swift)
│   │   ├── DictationModule.swift   # React Native bridge
│   │   ├── DictationCoordinator.swift
│   │   ├── AudioEngineManager.swift
│   │   └── SpeechRecognizerManager.swift
│   ├── android/                    # Android native implementation (Kotlin)
│   │   └── src/main/java/com/reactnativedictation/
│   │       ├── DictationModule.kt
│   │       ├── DictationCoordinator.kt
│   │       └── AudioEngineManager.kt
├── docs/react_native_migration/    # Implementation documentation
└── README.md                       # This file
```

## Documentation

- **`docs/react_native_migration/`** - Implementation documentation and phases
  - `01_NATIVE_MODULE_BRIDGE.md` - iOS native module setup
  - `08_ANDROID_IMPLEMENTATION.md` - Android implementation guide
  - `09_TESTING_AND_VALIDATION.md` - Testing strategy

## License

This project is available for use in your applications.
