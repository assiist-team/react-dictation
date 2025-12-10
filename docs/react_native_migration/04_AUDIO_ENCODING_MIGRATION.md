# Phase 4: Audio Encoding Migration

## Overview

The `AudioEncoderManager` handles encoding audio to the canonical format (AAC-LC .m4a, mono, 44.1kHz, 64kbps) and normalizing existing audio files. It's completely framework-agnostic.

## Migration Strategy

This file requires **zero changes** from the Flutter version. All dependencies are iOS frameworks (`AVFoundation`, `AudioToolbox`, `CoreMedia`).

## Files to Copy Directly

### 1. AudioEncoderManager.swift

Copy the entire file as-is. Key features:

- **Live Recording**: Encodes PCM buffers to AAC in real-time
- **Normalization**: Transcodes existing files to canonical format
- **Duration Limits**: 60-minute guardrail
- **Format Detection**: Fast-path copy for already-canonical files

```swift
// Copy directly from:
// flutter_dictation/ios/Classes/AudioEncoderManager.swift
// to:
// react-native-dictation/ios/ReactNativeDictation/AudioEncoderManager.swift
```

### 2. AudioPreservation.swift

Copy the struct definitions:

```swift
import AVFoundation
import Foundation

/// Represents a request to mirror the live audio stream into a file on disk.
struct AudioPreservationRequest {
    let fileURL: URL
}

/// Metadata about a successfully preserved audio file.
struct AudioPreservationResult {
    let fileURL: URL
    let durationMs: Double
    let fileSizeBytes: Int64
    let sampleRate: Double
    let channelCount: Int
}

// Note: AudioPreservationWriter is no longer needed as AudioEncoderManager
// handles direct AAC encoding. Keep the structs for API compatibility.
```

### 3. CanonicalAudioStorage.swift

Copy with minor namespace update:

```swift
import Foundation

/// Centralizes canonical recording directory creation and URL generation.
struct CanonicalAudioStorage {
    
    // Changed folder name to reflect React Native
    private static let recordingsFolderName = "DictationRecordings"
    
    private static let filenameDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withFullDate,
            .withTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime,
            .withTimeZone
        ]
        return formatter
    }()
    
    /// Returns the directory where canonical recordings live.
    static var recordingsDirectory: URL {
        let documentsURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
        let directory = documentsURL.appendingPathComponent(recordingsFolderName, isDirectory: true)
        ensureDirectoryExists(at: directory)
        return directory
    }
    
    /// Generates a deterministic file URL for a new canonical recording.
    static func makeRecordingURL() -> URL {
        let timestamp = filenameDateFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(6))
        let filename = "dictation_\(timestamp)_\(suffix).m4a"
        return recordingsDirectory.appendingPathComponent(filename)
    }
    
    /// Ensures the recordings directory exists.
    private static func ensureDirectoryExists(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            NSLog("[CanonicalAudioStorage] Failed to create recordings directory: \(error)")
        }
    }
}
```

## Canonical Format Specification

| Parameter | Value |
|-----------|-------|
| Container | MPEG-4 (.m4a) |
| Codec | AAC-LC |
| Sample Rate | 44,100 Hz |
| Channels | Mono (1) |
| Bitrate | 64,000 bps |
| Max Duration | 60 minutes |
| Max File Size | ~50 MB |

## TypeScript Types

```typescript
export interface NormalizedAudioResult {
  canonicalPath: string;
  durationMs: number;
  sizeBytes: number;
  wasReencoded: boolean;
}

export interface AudioFileMetadata {
  path: string;
  durationMs: number;
  fileSizeBytes: number;
  sampleRate: number;
  channelCount: number;
  wasCancelled: boolean;
}
```

## Error Types

The error types are already defined in `AudioEncoderManager.swift`:

```swift
enum EncodingError: Error {
    case invalidOutputFormat(String)   // "encoding_invalid_output"
    case formatCreationFailed(String)  // "encoding_format_failed"
    case writerCreationFailed(String)  // "encoding_writer_failed"
}

enum NormalizationError: Error {
    case fileNotFound(String)     // "file_not_found"
    case unsupportedFormat(String) // "unsupported_format"
    case durationTooLong(String)   // "duration_too_long"
    case ioError(String)           // "io_error"
    case encoderError(String)      // "encoder_error"
}
```

## Usage in Coordinator

The `AudioEncoderManager` is used in two places:

### 1. Live Recording (via AudioEngineManager)

```swift
// In AudioEngineManager.startRecording()
if let preservationRequest = audioPreservationRequest {
    let encoder = AudioEncoderManager()
    encoder.durationLimitReachedHandler = { [weak self] in
        self?.notifyDurationLimitReached()
    }
    try encoder.startRecording(outputURL: outputURL, sourceFormat: format)
    audioEncoderManager = encoder
}
```

### 2. File Normalization (via DictationModule)

```swift
// In DictationModule.normalizeAudio()
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
            
            await MainActor.run { resolve(response) }
        } catch {
            // Handle error...
        }
    }
}
```

## Normalization Flow

```
┌───────────────────────────────────────────────────────────────┐
│ normalizeAudio(sourcePath)                                    │
│                                                               │
│   1. Validate source file exists                              │
│                  │                                            │
│                  ▼                                            │
│   2. Load asset duration                                      │
│                  │                                            │
│                  ▼                                            │
│   3. Check duration limit (≤60 min)                           │
│                  │                                            │
│                  ▼                                            │
│   4. Load audio track & format description                    │
│                  │                                            │
│   ┌──────────────┴──────────────┐                             │
│   │                             │                             │
│   ▼                             ▼                             │
│ Already Canonical?           No                               │
│   │                             │                             │
│   ▼                             ▼                             │
│ Fast-path copy            Transcode to AAC                    │
│ (wasReencoded=false)      (wasReencoded=true)                 │
│   │                             │                             │
│   └──────────────┬──────────────┘                             │
│                  │                                            │
│                  ▼                                            │
│   5. Return NormalizedAudioResult                             │
│      { canonicalPath, durationMs, sizeBytes, wasReencoded }   │
└───────────────────────────────────────────────────────────────┘
```

## Testing

### Test Live Encoding

```swift
func testLiveEncoding() async throws {
    let audioEngine = AudioEngineManager()
    try audioEngine.initialize()
    
    let outputURL = CanonicalAudioStorage.makeRecordingURL()
    let request = AudioPreservationRequest(fileURL: outputURL)
    
    try await audioEngine.startRecording(audioPreservationRequest: request)
    
    // Record for 5 seconds
    try await Task.sleep(nanoseconds: 5_000_000_000)
    
    let result = audioEngine.stopRecording()
    
    XCTAssertNotNil(result)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result!.fileURL.path))
    XCTAssertGreaterThan(result!.durationMs, 4000) // At least 4 seconds
    XCTAssertEqual(result!.sampleRate, 44100)
    XCTAssertEqual(result!.channelCount, 1)
}
```

### Test Normalization

```swift
func testNormalization() async throws {
    let encoder = AudioEncoderManager()
    
    // Assuming you have a test file
    let sourcePath = "/path/to/test/audio.wav"
    
    let result = try await encoder.normalizeAudio(sourcePath: sourcePath)
    
    XCTAssertTrue(result.canonicalPath.hasSuffix(".m4a"))
    XCTAssertTrue(result.wasReencoded) // WAV should be re-encoded
    XCTAssertGreaterThan(result.sizeBytes, 0)
}
```

### Test Fast-Path Copy

```swift
func testFastPathCopy() async throws {
    let encoder = AudioEncoderManager()
    
    // Create a canonical file first
    let originalResult = try await createCanonicalTestFile()
    
    // Normalize it - should use fast-path
    let result = try await encoder.normalizeAudio(sourcePath: originalResult.fileURL.path)
    
    XCTAssertFalse(result.wasReencoded) // Should be fast-path copy
    XCTAssertEqual(result.durationMs, originalResult.durationMs, accuracy: 10)
}
```

## File Size Estimation

At 64 kbps AAC:
- 1 minute ≈ 480 KB
- 10 minutes ≈ 4.8 MB
- 60 minutes ≈ 28.8 MB

The 50 MB limit provides headroom for overhead and variable bitrate fluctuations.

## Verification Checklist

- [ ] `AudioEncoderManager.swift` compiles without modifications
- [ ] `AudioPreservation.swift` structs are available
- [ ] `CanonicalAudioStorage.swift` creates directories correctly
- [ ] Live encoding produces valid .m4a files
- [ ] Normalization handles various input formats
- [ ] Duration limit triggers callback at 60 minutes
- [ ] Fast-path copy works for already-canonical files

## Next Steps

Proceed to [05_DICTATION_COORDINATOR.md](./05_DICTATION_COORDINATOR.md) to create the DictationCoordinator that orchestrates all managers.
