# Phase 3: Speech Recognizer Manager Migration

## Overview

The `SpeechRecognizerManager` wraps Apple's `SFSpeechRecognizer` for real-time speech recognition. Like `AudioEngineManager`, it's framework-agnostic and requires minimal changes for React Native.

## Migration Strategy

The existing Swift code has no Flutter dependencies. We only need to:
1. Update dispatch queue labels
2. Simplify logging
3. Keep the callback-based interface

## Implementation

### SpeechRecognizerManager.swift (React Native Version)

```swift
import AVFoundation
import Foundation
import Speech

/// Manages SFSpeechRecognizer for low-latency speech recognition.
/// Provides real-time partial results integrated with the audio engine.
///
/// NOTE: This file is largely unchanged from the Flutter version.
/// It is framework-agnostic and works identically in React Native.
class SpeechRecognizerManager {
    
    // MARK: - Properties
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var resultCallback: ((String, Bool) -> Void)?
    private var statusCallback: ((String) -> Void)?
    
    private var state: RecognitionState = .idle
    private let stateQueue = DispatchQueue(label: "com.reactnativedictation.speechRecognizer.state")
    
    private var isAuthorized: Bool = false
    private weak var currentInputNode: AVAudioInputNode?
    private var bufferCount: Int = 0
    
    // MARK: - State Management
    
    enum RecognitionState {
        case idle
        case initializing
        case listening
        case processing
        case stopped
        case cancelled
    }
    
    // MARK: - Initialization
    
    /// Initializes the speech recognizer with optimal configuration for dictation.
    /// Should be called at app launch for pre-warming.
    /// - Parameter locale: BCP-47 locale identifier (e.g., "en-US", "es-ES"). Defaults to current locale.
    func initialize(locale: Locale = Locale.current) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        if recognizer != nil && isAuthorized {
            return
        }
        
        // Request authorization
        let authorized = await requestAuthorization()
        
        guard authorized else {
            throw SpeechRecognizerError.notAuthorized
        }
        
        // Create recognizer with specified locale
        recognizer = SFSpeechRecognizer(locale: locale)
        
        guard let recognizer = recognizer else {
            throw SpeechRecognizerError.notAvailable
        }
        
        // Configure for dictation (long-form speech)
        recognizer.defaultTaskHint = .dictation
        
        // Note: supportsOnDeviceRecognition is read-only - we check it but cannot set it
        // On-device preference is set on the recognition request instead
        
        guard recognizer.isAvailable else {
            throw SpeechRecognizerError.notAvailable
        }
        
        isAuthorized = true
        stateQueue.sync {
            self.state = .idle
        }
        
        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("Speech recognizer initialized in \(String(format: "%.2f", totalDuration))ms")
    }
    
    // MARK: - Authorization
    
    /// Requests speech recognition authorization.
    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    // MARK: - Recognition Control
    
    /// Starts speech recognition with the provided audio engine.
    /// Uses shared buffer approach - receives buffers from AudioEngineManager.
    func startRecognition(audioEngine: AVAudioEngine) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        guard let recognizer = recognizer else {
            throw SpeechRecognizerError.notInitialized
        }
        
        guard recognizer.isAvailable else {
            throw SpeechRecognizerError.notAvailable
        }
        
        // Check authorization
        if !isAuthorized {
            let authorized = await requestAuthorization()
            guard authorized else {
                throw SpeechRecognizerError.notAuthorized
            }
            isAuthorized = true
        }
        
        // Cancel any existing recognition task
        cancelRecognition()
        
        stateQueue.sync {
            self.state = .initializing
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            stateQueue.sync {
                self.state = .idle
            }
            throw SpeechRecognizerError.requestCreationFailed
        }
        
        // Configure for real-time results
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        
        // Prefer on-device recognition for lower latency and privacy (iOS 13+)
        // iOS automatically falls back to server if on-device isn't available
        if #available(iOS 13.0, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        let inputNode = audioEngine.inputNode
        currentInputNode = inputNode
        
        // Start recognition task
        recognitionTask = recognizer.recognitionTask(
            with: recognitionRequest
        ) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error)
        }
        
        stateQueue.sync {
            self.state = .listening
        }
        
        statusCallback?("listening")
        
        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("Recognition started in \(String(format: "%.2f", totalDuration))ms")
    }
    
    /// Appends an audio buffer to the recognition request.
    /// Called by AudioEngineManager's buffer callback.
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        
        let shouldAppend = stateQueue.sync {
            return self.state == .listening || self.state == .initializing
        }
        
        guard shouldAppend else { return }
        
        guard let request = recognitionRequest else { return }
        
        request.append(buffer)
    }
    
    /// Stops speech recognition gracefully.
    func stopRecognition() {
        stateQueue.sync {
            guard self.state == .listening || self.state == .initializing else {
                return
            }
            self.state = .processing
        }
        
        recognitionRequest?.endAudio()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.stateQueue.sync {
                self?.state = .stopped
            }
            self?.statusCallback?("stopped")
        }
    }
    
    /// Cancels speech recognition immediately.
    func cancelRecognition() {
        stateQueue.sync {
            guard self.state != .idle && self.state != .cancelled else {
                return
            }
        }
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        currentInputNode = nil
        
        stateQueue.sync {
            self.state = .cancelled
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.stateQueue.sync {
                if self?.state == .cancelled {
                    self?.state = .idle
                }
            }
        }
        
        statusCallback?("cancelled")
    }
    
    // MARK: - Result Handling
    
    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            log("Recognition error: \(error)")
            handleRecognitionError(error)
            return
        }
        
        guard let result = result else { return }
        
        let transcription = result.bestTranscription.formattedString
        
        resultCallback?(transcription, result.isFinal)
        
        if result.isFinal {
            stateQueue.sync {
                self.state = .processing
            }
            statusCallback?("done")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.stateQueue.sync {
                    self?.state = .stopped
                }
            }
        } else {
            stateQueue.sync {
                if self.state != .listening {
                    self.state = .listening
                }
            }
            statusCallback?("listening")
        }
    }
    
    // MARK: - Error Handling
    
    private func handleRecognitionError(_ error: Error) {
        let nsError = error as NSError
        let errorCode = nsError.code
        
        switch errorCode {
        case 201: // notAuthorized
            isAuthorized = false
            stateQueue.sync { self.state = .idle }
            statusCallback?("error:notAuthorized")
            
        case 209: // notAvailable
            stateQueue.sync { self.state = .idle }
            statusCallback?("error:notAvailable")
            
        case 216: // recognitionTaskUnavailable
            stateQueue.sync { self.state = .idle }
            statusCallback?("error:taskUnavailable")
            
        default:
            stateQueue.sync { self.state = .stopped }
            statusCallback?("error:\(error.localizedDescription)")
        }
    }
    
    // MARK: - Callbacks
    
    func setResultCallback(_ callback: @escaping (String, Bool) -> Void) {
        resultCallback = callback
    }
    
    func setStatusCallback(_ callback: @escaping (String) -> Void) {
        statusCallback = callback
    }
    
    // MARK: - State Queries
    
    var isListening: Bool {
        return stateQueue.sync {
            return self.state == .listening || self.state == .initializing
        }
    }
    
    var currentState: RecognitionState {
        return stateQueue.sync { self.state }
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        #if DEBUG
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
        print("[\(timestamp)] [SpeechRecognizerManager] \(message)")
        #endif
    }
    
    // MARK: - Cleanup
    
    deinit {
        cancelRecognition()
    }
}

// MARK: - Error Types

enum SpeechRecognizerError: Error {
    case notInitialized
    case notAuthorized
    case notAvailable
    case requestCreationFailed
    
    var localizedDescription: String {
        switch self {
        case .notInitialized:
            return "Speech recognizer not initialized"
        case .notAuthorized:
            return "Speech recognition authorization denied"
        case .notAvailable:
            return "Speech recognition not available"
        case .requestCreationFailed:
            return "Failed to create recognition request"
        }
    }
}
```

## Locale Configuration

The speech recognizer now accepts a locale parameter during initialization. The locale is propagated from the TypeScript service through the native module bridge.

### Swift Implementation

The `initialize()` method accepts a `Locale` parameter (defaults to `Locale.current`):

```swift
func initialize(locale: Locale = Locale.current) async throws {
    // ... existing code ...
    
    recognizer = SFSpeechRecognizer(locale: locale)
    
    // ... rest of initialization ...
}
```

### TypeScript Interface

The TypeScript service accepts locale in the initialize options:

```typescript
// Usage with locale (BCP-47 format)
await dictationService.initialize({ locale: 'es-ES' });

// Or use default (current system locale)
await dictationService.initialize();
```

Supported locale format: BCP-47 identifiers such as `en-US`, `es-ES`, `fr-FR`, etc.

## On-Device Recognition

The manager prefers on-device recognition when available (iOS 13+). This provides:
- Lower latency
- Better privacy (no server round-trip)
- Offline capability for supported languages

**Important:** `SFSpeechRecognizer.supportsOnDeviceRecognition` is a read-only property. We cannot set it directly. Instead, we set `requiresOnDeviceRecognition = true` on the `SFSpeechAudioBufferRecognitionRequest`. iOS automatically falls back to server-based recognition if on-device isn't available for the requested locale.

**Note:** Certain locales may still fall back to server-based recognition even when on-device is preferred, depending on device capabilities and language pack availability.

To check if on-device is available:

```swift
func supportsOnDeviceRecognition() -> Bool {
    guard let recognizer = recognizer else { return false }
    
    if #available(iOS 13.0, *) {
        return recognizer.supportsOnDeviceRecognition
    }
    return false
}
```

## Buffer Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ AudioEngineManager                                              │
│   ┌─────────────────┐                                           │
│   │ AVAudioEngine   │                                           │
│   │ inputNode.tap() │ ───▶ processAudioBuffer()                 │
│   └─────────────────┘            │                              │
│                                  │                              │
│                                  ▼                              │
│                        bufferCallback(buffer)                   │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ SpeechRecognizerManager                                         │
│                                                                 │
│   appendAudioBuffer(buffer)                                     │
│          │                                                      │
│          ▼                                                      │
│   recognitionRequest.append(buffer)                             │
│          │                                                      │
│          ▼                                                      │
│   SFSpeechRecognitionTask                                       │
│          │                                                      │
│          ▼                                                      │
│   handleRecognitionResult(result, error)                        │
│          │                                                      │
│          ▼                                                      │
│   resultCallback(text, isFinal)                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Error Code Reference

| Code | SFSpeechRecognizer Error | Mapped Status |
|------|--------------------------|---------------|
| 201 | notAuthorized | `error:notAuthorized` |
| 209 | notAvailable | `error:notAvailable` |
| 216 | recognitionTaskUnavailable | `error:taskUnavailable` |
| Other | Network/unknown errors | `error:<description>` |

## Testing

### Unit Test: Buffer Appending

```swift
func testBufferAppending() async throws {
    let manager = SpeechRecognizerManager()
    try await manager.initialize()
    
    // Create mock audio engine (just for format info)
    let audioEngine = AVAudioEngine()
    try await manager.startRecognition(audioEngine: audioEngine)
    
    // Verify state
    XCTAssertTrue(manager.isListening)
    XCTAssertEqual(manager.currentState, .listening)
    
    manager.cancelRecognition()
}
```

### Integration Test: Full Recognition Flow

```swift
func testFullRecognitionFlow() async throws {
    let audioManager = AudioEngineManager()
    let speechManager = SpeechRecognizerManager()
    
    try audioManager.initialize()
    try await speechManager.initialize()
    
    var receivedText: String?
    var receivedFinal = false
    
    speechManager.setResultCallback { text, isFinal in
        receivedText = text
        receivedFinal = isFinal
    }
    
    // Start recording
    try await audioManager.startRecording()
    try await speechManager.startRecognition(audioEngine: audioManager.engine)
    
    // Set up buffer forwarding
    audioManager.setBufferCallback { buffer in
        speechManager.appendAudioBuffer(buffer)
    }
    
    // Speak into mic for a few seconds...
    try await Task.sleep(nanoseconds: 5_000_000_000)
    
    // Stop
    speechManager.stopRecognition()
    audioManager.stopRecording()
    
    // Verify we got some text
    XCTAssertNotNil(receivedText)
}
```

## Verification Checklist

- [ ] `SpeechRecognizerManager.swift` compiles without Flutter imports
- [ ] Authorization request triggers system permission dialog
- [ ] Partial results are emitted during speech
- [ ] Final result is emitted after `stopRecognition()`
- [ ] `cancelRecognition()` discards partial results
- [ ] Error codes are properly mapped
- [ ] Buffer callback receives audio data

## Next Steps

Proceed to [04_AUDIO_ENCODING_MIGRATION.md](./04_AUDIO_ENCODING_MIGRATION.md) to migrate the AudioEncoderManager.
