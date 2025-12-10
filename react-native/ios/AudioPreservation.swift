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
