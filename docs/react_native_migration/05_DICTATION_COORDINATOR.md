# Phase 5: Dictation Coordinator

## Overview

The `DictationCoordinator` replaces Flutter's `DictationManager`. It orchestrates `AudioEngineManager` and `SpeechRecognizerManager`, manages the state machine, and emits events to JavaScript via the `DictationModule`.

## Key Differences from Flutter

| Flutter (DictationManager) | React Native (DictationCoordinator) |
|----------------------------|-------------------------------------|
| `FlutterEventSink` | `DictationModule.emitXxx()` |
| `FlutterStreamHandler` protocol | Direct callback pattern |
| Timer for audio levels | Same approach (Timer) |
| Dispatch queues | Same approach |

## Implementation

### DictationCoordinator.swift

```swift
import AVFoundation
import Foundation

/// Coordinates AudioEngineManager and SpeechRecognizerManager.
/// Handles method calls from DictationModule and emits events back to JavaScript.
class DictationCoordinator: NSObject, AudioEngineManagerDelegate {
    
    // MARK: - Properties
    
    private let audioEngineManager: AudioEngineManager
    private let speechRecognizerManager: SpeechRecognizerManager
    private weak var eventEmitter: DictationModule?
    
    private var audioLevelTimer: Timer?
    private var isStreamingAudioLevels = false
    private let audioLevelQueue = DispatchQueue(label: "com.reactnativedictation.coordinator.audioLevel")
    
    private var state: DictationState = .idle
    private let stateQueue = DispatchQueue(label: "com.reactnativedictation.coordinator.state")
    
    private var audioPreservationConfig: AudioPreservationConfig?
    private var isHandlingDurationLimit = false
    
    // MARK: - State Management
    
    enum DictationState {
        case idle
        case initializing
        case listening
        case stopping
        case stopped
    }
    
    // MARK: - Initialization
    
    init(eventEmitter: DictationModule) {
        self.eventEmitter = eventEmitter
        self.audioEngineManager = AudioEngineManager()
        self.speechRecognizerManager = SpeechRecognizerManager()
        
        super.init()
        
        self.audioEngineManager.delegate = self
        setupSpeechRecognizerCallbacks()
    }
    
    // MARK: - Public Methods
    
    /// Initialize audio engine and speech recognizer.
    /// - Parameter locale: BCP-47 locale identifier (e.g., "en-US", "es-ES"). Defaults to current locale.
    func initialize(locale: Locale = Locale.current) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        log("=== INITIALIZE START ===")
        
        do {
            // Initialize audio engine
            log("Initializing audio engine...")
            try audioEngineManager.initialize()
            log("Audio engine initialized")
            
            // Initialize speech recognizer with locale
            log("Initializing speech recognizer with locale: \(locale.identifier)...")
            try await speechRecognizerManager.initialize(locale: locale)
            log("Speech recognizer initialized")
            
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            log("=== INITIALIZE COMPLETE in \(String(format: "%.2f", duration))ms ===")
            
            await MainActor.run {
                self.stateQueue.sync { self.state = .idle }
                self.eventEmitter?.emitStatus("ready")
            }
        } catch {
            let dictationError = DictationError.from(error)
            log("=== INITIALIZE FAILED: \(dictationError.localizedDescription) ===")
            throw dictationError
        }
    }
    
    /// Start listening for speech recognition.
    func startListening(options: DictationStartOptions) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        log("=== START LISTENING ===")
        log("Options: preserveAudio=\(options.preserveAudio)")
        
        // Validate state
        try stateQueue.sync {
            guard self.state == .idle || self.state == .stopped else {
                log("Invalid state for startListening: \(self.state)")
                throw DictationError.invalidArguments("Cannot start listening - invalid state")
            }
            self.state = .initializing
        }
        
        do {
            // Configure audio preservation
            var preservationRequest: AudioPreservationRequest? = nil
            if options.preserveAudio {
                let fileURL = try AudioPreservationConfig.resolveFileURL(customPath: options.preservedAudioFilePath)
                audioPreservationConfig = AudioPreservationConfig(
                    fileURL: fileURL,
                    deleteIfCancelled: options.deleteAudioIfCancelled
                )
                preservationRequest = AudioPreservationRequest(fileURL: fileURL)
            }
            
            // Start audio engine
            log("Starting audio engine...")
            try await audioEngineManager.startRecording(audioPreservationRequest: preservationRequest)
            log("Audio engine started")
            
            // Set up buffer callback for speech recognition
            audioEngineManager.setBufferCallback { [weak self] buffer in
                self?.speechRecognizerManager.appendAudioBuffer(buffer)
            }
            
            // Start speech recognition
            log("Starting speech recognition...")
            try await speechRecognizerManager.startRecognition(
                audioEngine: audioEngineManager.engine
            )
            log("Speech recognition started")
            
            // Start audio level streaming
            try startAudioLevelStreaming()
            
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            log("=== START LISTENING COMPLETE in \(String(format: "%.2f", duration))ms ===")
            
            await MainActor.run {
                self.stateQueue.sync { self.state = .listening }
                self.eventEmitter?.emitStatus("listening")
            }
        } catch {
            // Clean up on failure
            audioPreservationConfig = nil
            stateQueue.sync { self.state = .stopped }
            
            let dictationError = DictationError.from(error)
            log("=== START LISTENING FAILED: \(dictationError.localizedDescription) ===")
            
            await MainActor.run {
                self.eventEmitter?.emitError(
                    message: dictationError.localizedDescription,
                    code: dictationError.code
                )
            }
            
            throw dictationError
        }
    }
    
    /// Stop listening and finalize result.
    func stopListening() async throws {
        log("=== STOP LISTENING ===")
        
        try stateQueue.sync {
            guard self.state == .listening else {
                return
            }
            self.state = .stopping
        }
        
        // Stop audio level streaming
        stopAudioLevelStreaming()
        
        // Remove buffer callback
        audioEngineManager.removeBufferCallback()
        
        // Stop speech recognition (will finalize result)
        speechRecognizerManager.stopRecognition()
        
        // Stop audio engine
        let preservationResult = audioEngineManager.stopRecording(deletePreservedAudio: false)
        let preservationConfig = self.audioPreservationConfig
        self.audioPreservationConfig = nil
        
        await MainActor.run {
            self.stateQueue.sync { self.state = .stopped }
            self.eventEmitter?.emitStatus("stopped")
            
            // Emit audio file event if preservation was enabled
            if let config = preservationConfig, let result = preservationResult {
                self.eventEmitter?.emitAudioFile(
                    path: result.fileURL.path,
                    durationMs: result.durationMs,
                    fileSizeBytes: result.fileSizeBytes,
                    sampleRate: result.sampleRate,
                    channelCount: result.channelCount,
                    wasCancelled: false
                )
            }
        }
        
        log("=== STOP LISTENING COMPLETE ===")
    }
    
    /// Cancel listening without finalizing.
    func cancelListening() async throws {
        log("=== CANCEL LISTENING ===")
        
        stateQueue.sync {
            guard self.state == .listening || self.state == .initializing else {
                return
            }
        }
        
        // Stop audio level streaming
        stopAudioLevelStreaming()
        
        // Remove buffer callback
        audioEngineManager.removeBufferCallback()
        
        // Cancel speech recognition
        speechRecognizerManager.cancelRecognition()
        
        // Stop audio engine
        let preservationConfig = self.audioPreservationConfig
        let shouldDeleteAudio = preservationConfig?.deleteIfCancelled ?? true
        let preservationResult = audioEngineManager.stopRecording(deletePreservedAudio: shouldDeleteAudio)
        self.audioPreservationConfig = nil
        
        await MainActor.run {
            self.stateQueue.sync { self.state = .stopped }
            self.eventEmitter?.emitStatus("cancelled")
            
            // Emit audio file event if preservation was enabled and not deleted
            if let config = preservationConfig,
               !config.deleteIfCancelled,
               let result = preservationResult {
                self.eventEmitter?.emitAudioFile(
                    path: result.fileURL.path,
                    durationMs: result.durationMs,
                    fileSizeBytes: result.fileSizeBytes,
                    sampleRate: result.sampleRate,
                    channelCount: result.channelCount,
                    wasCancelled: true
                )
            }
        }
        
        log("=== CANCEL LISTENING COMPLETE ===")
    }
    
    /// Get current audio level for waveform.
    func getAudioLevel() -> Float {
        return audioEngineManager.getAudioLevel()
    }
    
    // MARK: - Speech Recognizer Callbacks
    
    private func setupSpeechRecognizerCallbacks() {
        speechRecognizerManager.setResultCallback { [weak self] text, isFinal in
            DispatchQueue.main.async {
                self?.eventEmitter?.emitResult(text: text, isFinal: isFinal)
            }
        }
        
        speechRecognizerManager.setStatusCallback { [weak self] status in
            // Status updates are handled by coordinator, not forwarded directly
            self?.log("Speech recognizer status: \(status)")
        }
    }
    
    // MARK: - Audio Level Streaming
    
    private func startAudioLevelStreaming() throws {
        log("Starting audio level streaming...")
        
        // Clear any existing timer
        if Thread.isMainThread {
            audioLevelTimer?.invalidate()
            audioLevelTimer = nil
        } else {
            DispatchQueue.main.sync {
                audioLevelTimer?.invalidate()
                audioLevelTimer = nil
            }
        }
        
        audioLevelQueue.sync {
            guard !isStreamingAudioLevels else { return }
            isStreamingAudioLevels = true
        }
        
        // Create timer on main thread for 30 FPS
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let shouldStream = self.audioLevelQueue.sync { self.isStreamingAudioLevels }
            guard shouldStream else { return }
            
            self.audioLevelTimer = Timer.scheduledTimer(
                withTimeInterval: 0.033, // ~30 FPS
                repeats: true
            ) { [weak self] _ in
                guard let self = self else { return }
                
                let shouldContinue = self.audioLevelQueue.sync { self.isStreamingAudioLevels }
                guard shouldContinue else {
                    self.stopAudioLevelStreaming()
                    return
                }
                
                let level = self.audioEngineManager.getAudioLevel()
                self.eventEmitter?.emitAudioLevel(level)
            }
            
            // Add to run loop
            if let timer = self.audioLevelTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        
        log("Audio level streaming started")
    }
    
    private func stopAudioLevelStreaming() {
        log("Stopping audio level streaming...")
        
        audioLevelQueue.sync {
            isStreamingAudioLevels = false
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.audioLevelTimer?.invalidate()
            self?.audioLevelTimer = nil
        }
    }
    
    // MARK: - AudioEngineManagerDelegate
    
    func audioEngineManagerDidHitDurationLimit(_ manager: AudioEngineManager) {
        log("Duration limit reached")
        handleDurationLimitReached()
    }
    
    func audioEngineManager(_ manager: AudioEngineManager, didEncounterEncodingError error: Error) {
        log("Encoding error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.eventEmitter?.emitError(
                message: "Audio encoding error: \(error.localizedDescription)",
                code: "encoding_error"
            )
        }
    }
    
    private func handleDurationLimitReached() {
        guard !isHandlingDurationLimit else { return }
        isHandlingDurationLimit = true
        
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.isHandlingDurationLimit = false }
            
            self.stateQueue.sync {
                guard self.state == .listening else { return }
                self.state = .stopping
            }
            
            self.stopAudioLevelStreaming()
            self.audioEngineManager.removeBufferCallback()
            self.speechRecognizerManager.stopRecognition()
            
            let preservationResult = self.audioEngineManager.stopRecording(deletePreservedAudio: false)
            let config = self.audioPreservationConfig
            self.audioPreservationConfig = nil
            
            await MainActor.run {
                self.stateQueue.sync { self.state = .stopped }
                self.eventEmitter?.emitStatus("duration_limit_reached")
                self.eventEmitter?.emitError(
                    message: "Recording duration limit reached (60 minutes).",
                    code: "DURATION_LIMIT_REACHED"
                )
                
                if let config = config, let result = preservationResult {
                    self.eventEmitter?.emitAudioFile(
                        path: result.fileURL.path,
                        durationMs: result.durationMs,
                        fileSizeBytes: result.fileSizeBytes,
                        sampleRate: result.sampleRate,
                        channelCount: result.channelCount,
                        wasCancelled: false
                    )
                }
            }
        }
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
        print("[\(timestamp)] [DictationCoordinator] \(message)")
    }
    
    // MARK: - Cleanup
    
    deinit {
        stopAudioLevelStreaming()
        audioEngineManager.stopRecording()
        speechRecognizerManager.cancelRecognition()
    }
}

// MARK: - Audio Preservation Config

struct AudioPreservationConfig {
    private static let supportedFileExtensions: Set<String> = ["wav", "caf", "m4a"]
    
    let fileURL: URL
    let deleteIfCancelled: Bool
    
    static func resolveFileURL(customPath: String?) throws -> URL {
        let targetURL: URL
        
        if let path = customPath, !path.isEmpty {
            if path.hasPrefix("/") {
                targetURL = URL(fileURLWithPath: path)
            } else {
                targetURL = CanonicalAudioStorage.recordingsDirectory.appendingPathComponent(path)
            }
        } else {
            targetURL = CanonicalAudioStorage.makeRecordingURL()
        }
        
        return try sanitizedFileURL(from: targetURL)
    }
    
    private static func sanitizedFileURL(from url: URL) throws -> URL {
        var finalURL = url
        
        if finalURL.pathExtension.isEmpty {
            finalURL = finalURL.appendingPathExtension("m4a")
        }
        
        let ext = finalURL.pathExtension.lowercased()
        guard supportedFileExtensions.contains(ext) else {
            throw DictationError.invalidArguments(
                "Unsupported audio file extension \"\(ext)\". Use .wav, .caf, or .m4a."
            )
        }
        
        let directoryURL = finalURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw DictationError.invalidArguments("Failed to prepare directory: \(error.localizedDescription)")
        }
        
        return finalURL
    }
}
```

### DictationStartOptions Struct

The `DictationStartOptions` struct is defined in `DictationModule.swift` and mirrors the JavaScript `DictationSessionOptions`:

```swift
struct DictationStartOptions {
    let preserveAudio: Bool
    let preservedAudioFilePath: String?
    let deleteAudioIfCancelled: Bool
    
    static func from(dictionary: [String: Any]?) throws -> DictationStartOptions {
        guard let dict = dictionary else {
            return DictationStartOptions(
                preserveAudio: false,
                preservedAudioFilePath: nil,
                deleteAudioIfCancelled: true
            )
        }
        
        return DictationStartOptions(
            preserveAudio: dict["preserveAudio"] as? Bool ?? false,
            preservedAudioFilePath: (dict["preservedAudioFilePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            deleteAudioIfCancelled: dict["deleteAudioIfCancelled"] as? Bool ?? true
        )
    }
}
```

**JavaScript to Swift Mapping:**

| JavaScript Key | Swift Field | Type | Default |
|----------------|-------------|------|---------|
| `preserveAudio` | `preserveAudio` | `Bool` | `false` |
| `preservedAudioFilePath` | `preservedAudioFilePath` | `String?` | `nil` |
| `deleteAudioIfCancelled` | `deleteAudioIfCancelled` | `Bool` | `true` |

The struct is decoded from the React Native bridge arguments in `DictationModule.startListening()` and passed to `DictationCoordinator.startListening()`.

### DictationError.swift (shared error types)

```swift
import Foundation

/// Error types for the dictation module.
enum DictationError: Error {
    case notAuthorized
    case notAvailable
    case audioEngineFailed
    case recognitionFailed
    case initializationFailed
    case invalidArguments(String)
    case unknown(Error)
    
    var code: String {
        switch self {
        case .notAuthorized:
            return "NOT_AUTHORIZED"
        case .notAvailable:
            return "NOT_AVAILABLE"
        case .audioEngineFailed:
            return "AUDIO_ENGINE_ERROR"
        case .recognitionFailed:
            return "RECOGNITION_ERROR"
        case .initializationFailed:
            return "INIT_ERROR"
        case .invalidArguments:
            return "INVALID_ARGUMENTS"
        case .unknown:
            return "UNKNOWN_ERROR"
        }
    }
    
    var localizedDescription: String {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized. Please grant microphone and speech recognition permissions."
        case .notAvailable:
            return "Speech recognition is not available on this device."
        case .audioEngineFailed:
            return "Audio engine failed to start. Please try again."
        case .recognitionFailed:
            return "Speech recognition failed. Please try again."
        case .initializationFailed:
            return "Failed to initialize dictation service. Please try again."
        case .invalidArguments(let message):
            return message
        case .unknown(let error):
            return error.localizedDescription
        }
    }
    
    static func from(_ error: Error) -> DictationError {
        if let dictationError = error as? DictationError {
            return dictationError
        }
        
        if let speechError = error as? SpeechRecognizerError {
            switch speechError {
            case .notAuthorized:
                return .notAuthorized
            case .notAvailable:
                return .notAvailable
            case .notInitialized, .requestCreationFailed:
                return .initializationFailed
            }
        }
        
        let nsError = error as NSError
        if nsError.domain == "AudioEngineManager" {
            let errorMessage = nsError.localizedDescription.lowercased()
            if errorMessage.contains("permission") && errorMessage.contains("denied") {
                return .notAuthorized
            }
            return .audioEngineFailed
        }
        
        return .unknown(error)
    }
}
```

## State Machine Diagram

```
                    ┌─────────────────────┐
                    │                     │
                    │       idle          │◄───────────────────────┐
                    │                     │                        │
                    └──────────┬──────────┘                        │
                               │                                   │
                    initialize()│                                   │
                               ▼                                   │
                    ┌─────────────────────┐                        │
                    │                     │                        │
                    │   initializing      │                        │
                    │                     │                        │
                    └──────────┬──────────┘                        │
                               │                                   │
                   startListening()                                │
                               │                                   │
                               ▼                                   │
    ┌─────────────────────────────────────────────────────────┐    │
    │                                                         │    │
    │                      listening                          │    │
    │                                                         │    │
    └────────────┬──────────────────────────┬─────────────────┘    │
                 │                          │                      │
      stopListening()              cancelListening()               │
                 │                          │                      │
                 ▼                          ▼                      │
    ┌─────────────────────┐    ┌─────────────────────┐             │
    │                     │    │                     │             │
    │      stopping       │    │      stopped        │─────────────┤
    │                     │    │    (cancelled)      │             │
    └──────────┬──────────┘    └─────────────────────┘             │
               │                                                   │
               ▼                                                   │
    ┌─────────────────────┐                                        │
    │                     │                                        │
    │      stopped        │────────────────────────────────────────┘
    │                     │        (ready for next session)
    └─────────────────────┘
```

## Verification Checklist

- [ ] `DictationCoordinator` compiles without errors
- [ ] State transitions are thread-safe
- [ ] Events are emitted to JavaScript correctly
- [ ] Audio level streaming runs at ~30 FPS
- [ ] Duration limit triggers proper cleanup
- [ ] Audio preservation works end-to-end

## Next Steps

Proceed to [06_TYPESCRIPT_SERVICE_LAYER.md](./06_TYPESCRIPT_SERVICE_LAYER.md) to implement the TypeScript service and hooks.
