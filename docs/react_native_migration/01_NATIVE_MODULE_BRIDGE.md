# Phase 1: iOS Native Module Bridge

## Overview

This phase creates the React Native native module bridge for iOS, establishing the communication layer between JavaScript and Swift. The bridge replaces Flutter's `MethodChannel` and `EventChannel` with React Native's `RCTBridgeModule` and `RCTEventEmitter`.

## Key Differences: Flutter vs React Native

| Concept | Flutter | React Native |
|---------|---------|--------------|
| Method calls | `MethodChannel.invokeMethod()` | `@objc func` with Promise |
| Events to JS | `EventChannel` + `EventSink` | `RCTEventEmitter.sendEvent()` |
| Async returns | `FlutterResult` callback | Promise `resolve`/`reject` |
| Module registration | `FlutterPlugin.register()` | `RCT_EXPORT_MODULE()` |

## Implementation

### 1. Objective-C Export Macros

**DictationModule.m**
```objc
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(DictationModule, RCTEventEmitter)

RCT_EXTERN_METHOD(initialize:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(startListening:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(stopListening:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(cancelListening:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getAudioLevel:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(normalizeAudio:(NSString *)sourcePath
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

// Required for event emitter
+ (BOOL)requiresMainQueueSetup {
    return YES;
}

@end
```

### 2. Swift Module Implementation

**DictationModule.swift**
```swift
import Foundation
import AVFoundation

@objc(DictationModule)
class DictationModule: RCTEventEmitter {
    
    // MARK: - Properties
    
    private var coordinator: DictationCoordinator?
    private var hasListeners = false
    
    // MARK: - Module Setup
    
    override init() {
        super.init()
        // Coordinator will be initialized lazily or in initialize()
    }
    
    /// Required: List of events this module can emit
    override func supportedEvents() -> [String]! {
        return [
            "onResult",
            "onStatus", 
            "onAudioLevel",
            "onAudioFile",
            "onError"
        ]
    }
    
    /// Called when JS starts listening to events
    override func startObserving() {
        hasListeners = true
    }
    
    /// Called when JS stops listening to events
    override func stopObserving() {
        hasListeners = false
    }
    
    /// Ensures module methods run on main thread for permission dialogs
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    // MARK: - Bridge Methods
    
    /// Initialize the dictation service (pre-warm audio engine + speech recognizer)
    @objc func initialize(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task { @MainActor in
            do {
                // Create coordinator if needed
                if coordinator == nil {
                    coordinator = DictationCoordinator(eventEmitter: self)
                }
                
                try await coordinator?.initialize()
                resolve(nil)
            } catch {
                let dictationError = DictationError.from(error)
                reject(dictationError.code, dictationError.localizedDescription, error)
            }
        }
    }
    
    /// Start listening for speech recognition
    @objc func startListening(
        _ options: NSDictionary?,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task { @MainActor in
            guard let coordinator = coordinator else {
                reject("NOT_INITIALIZED", "Dictation service not initialized. Call initialize() first.", nil)
                return
            }
            
            do {
                let parsedOptions = try DictationStartOptions.from(dictionary: options as? [String: Any])
                try await coordinator.startListening(options: parsedOptions)
                resolve(nil)
            } catch {
                let dictationError = DictationError.from(error)
                reject(dictationError.code, dictationError.localizedDescription, error)
            }
        }
    }
    
    /// Stop listening and finalize result
    @objc func stopListening(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task {
            do {
                try await coordinator?.stopListening()
                resolve(nil)
            } catch {
                let dictationError = DictationError.from(error)
                reject(dictationError.code, dictationError.localizedDescription, error)
            }
        }
    }
    
    /// Cancel listening without finalizing
    @objc func cancelListening(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task {
            do {
                try await coordinator?.cancelListening()
                resolve(nil)
            } catch {
                let dictationError = DictationError.from(error)
                reject(dictationError.code, dictationError.localizedDescription, error)
            }
        }
    }
    
    /// Get current audio level for waveform
    @objc func getAudioLevel(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        guard let coordinator = coordinator else {
            resolve(0.0)
            return
        }
        
        let level = coordinator.getAudioLevel()
        resolve(level)
    }
    
    /// Normalize an audio file to canonical format
    @objc func normalizeAudio(
        _ sourcePath: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task {
            do {
                let encoder = AudioEncoderManager()
                let result = try await encoder.normalizeAudio(sourcePath: sourcePath)
                
                let response: [String: Any] = [
                    "canonicalPath": result.canonicalPath,
                    "durationMs": Int(result.durationMs),
                    "sizeBytes": result.sizeBytes,
                    "wasReencoded": result.wasReencoded
                ]
                
                await MainActor.run {
                    resolve(response)
                }
            } catch {
                let normError = error as? NormalizationError ?? 
                    NormalizationError.encoderError("Unknown error: \(error.localizedDescription)")
                
                await MainActor.run {
                    reject(normError.code, normError.localizedDescription, error)
                }
            }
        }
    }
    
    // MARK: - Event Emission Helpers
    
    /// Send result event to JavaScript
    func emitResult(text: String, isFinal: Bool) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onResult", body: [
            "text": text,
            "isFinal": isFinal
        ])
    }
    
    /// Send status event to JavaScript
    func emitStatus(_ status: String) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onStatus", body: [
            "status": status
        ])
    }
    
    /// Send audio level event to JavaScript
    func emitAudioLevel(_ level: Float) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onAudioLevel", body: [
            "level": level
        ])
    }
    
    /// Send audio file event to JavaScript
    func emitAudioFile(
        path: String,
        durationMs: Double,
        fileSizeBytes: Int64,
        sampleRate: Double,
        channelCount: Int,
        wasCancelled: Bool
    ) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onAudioFile", body: [
            "path": path,
            "durationMs": durationMs,
            "fileSizeBytes": fileSizeBytes,
            "sampleRate": sampleRate,
            "channelCount": channelCount,
            "wasCancelled": wasCancelled
        ])
    }
    
    /// Send error event to JavaScript
    func emitError(message: String, code: String? = nil) {
        guard hasListeners else { return }
        
        var body: [String: Any] = ["message": message]
        if let code = code {
            body["code"] = code
        }
        
        sendEvent(withName: "onError", body: body)
    }
    
    // MARK: - Cleanup
    
    deinit {
        coordinator = nil
    }
}

// MARK: - Options Parsing

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

### 3. Event Mapping Reference

| Flutter Event | React Native Event | Payload |
|---------------|-------------------|---------|
| `result` | `onResult` | `{ text: string, isFinal: boolean }` |
| `status` | `onStatus` | `{ status: string }` |
| `audioLevel` | `onAudioLevel` | `{ level: number }` |
| `audioFile` | `onAudioFile` | `{ path, durationMs, fileSizeBytes, sampleRate, channelCount, wasCancelled }` |
| `error` | `onError` | `{ message: string, code?: string }` |

### 4. Error Code Mapping

The error codes remain consistent between Flutter and React Native:

```swift
// Error codes (same as Flutter)
enum DictationError: Error {
    case notAuthorized        // "NOT_AUTHORIZED"
    case notAvailable         // "NOT_AVAILABLE"
    case audioEngineFailed    // "AUDIO_ENGINE_ERROR"
    case recognitionFailed    // "RECOGNITION_ERROR"
    case initializationFailed // "INIT_ERROR"
    case invalidArguments     // "INVALID_ARGUMENTS"
    case unknown              // "UNKNOWN_ERROR"
}
```

## TypeScript Type Definitions

Create corresponding TypeScript types for the JavaScript side:

**src/types/index.ts**
```typescript
export interface DictationSessionOptions {
  preserveAudio?: boolean;
  preservedAudioFilePath?: string;
  deleteAudioIfCancelled?: boolean;
}

export interface DictationResult {
  text: string;
  isFinal: boolean;
}

export interface DictationStatus {
  status: 
    | 'ready'
    | 'listening'
    | 'stopped'
    | 'cancelled'
    | 'duration_limit_reached'
    | `error:${string}`;
}

export interface DictationAudioLevel {
  level: number; // 0.0 - 1.0
}

export interface DictationAudioFile {
  path: string;
  durationMs: number;
  fileSizeBytes: number;
  sampleRate: number;
  channelCount: number;
  wasCancelled: boolean;
}

export interface DictationError {
  message: string;
  code?: string;
}

export interface NormalizedAudioResult {
  canonicalPath: string;
  durationMs: number;
  sizeBytes: number;
  wasReencoded: boolean;
}

// Native module interface
export interface DictationModuleInterface {
  initialize(): Promise<void>;
  startListening(options?: DictationSessionOptions): Promise<void>;
  stopListening(): Promise<void>;
  cancelListening(): Promise<void>;
  getAudioLevel(): Promise<number>;
  normalizeAudio(sourcePath: string): Promise<NormalizedAudioResult>;
}
```

## Verification Checklist

- [ ] `DictationModule.m` exports all methods correctly
- [ ] `DictationModule.swift` compiles without errors
- [ ] `supportedEvents()` returns all event names
- [ ] `requiresMainQueueSetup()` returns `true` (needed for permissions)
- [ ] Bridging header is properly configured
- [ ] Module is discoverable from JavaScript: `NativeModules.DictationModule`

## Next Steps

Proceed to [02_AUDIO_ENGINE_MIGRATION.md](./02_AUDIO_ENGINE_MIGRATION.md) to migrate the AudioEngineManager.
