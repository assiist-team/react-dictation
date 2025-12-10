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

/// Lightweight writer that persists audio tap buffers to disk without blocking the render thread.
final class AudioPreservationWriter {
    
    private let fileURL: URL
    private let format: AVAudioFormat
    private let audioFile: AVAudioFile
    private var totalFrames: AVAudioFramePosition = 0
    private let logPrefix = "[AudioPreservationWriter]"
    
    init(outputURL: URL, format: AVAudioFormat) throws {
        self.fileURL = outputURL
        self.format = format
        
        let directoryURL = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: AudioPreservationWriter.makeFileSettings(from: format)
        )
    }
    
    func append(_ buffer: AVAudioPCMBuffer) {
        do {
            try audioFile.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            NSLog("\(logPrefix) Failed to write buffer: \(error)")
        }
    }
    
    func finish(deleteFile: Bool) -> AudioPreservationResult? {
        if deleteFile {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        
        let durationSeconds = totalFrames > 0 ? Double(totalFrames) / format.sampleRate : 0
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        
        return AudioPreservationResult(
            fileURL: fileURL,
            durationMs: durationSeconds * 1000.0,
            fileSizeBytes: fileSize,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }
    
    private static func makeFileSettings(from format: AVAudioFormat) -> [String: Any] {
        var settings = format.settings
        settings[AVEncoderAudioQualityKey] = AVAudioQuality.high.rawValue
        return settings
    }
}


