import Foundation

/// Centralizes canonical recording directory creation and URL generation.
/// Ensures both live recordings and normalized files use the same managed folder.
struct CanonicalAudioStorage {
    
    private static let recordingsFolderName = "ReactNativeDictationRecordings"
    
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
        let timestamp = filenameDateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
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
