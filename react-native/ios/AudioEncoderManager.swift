import AVFoundation
import Foundation
import CoreMedia
import AudioToolbox

/// Manages audio encoding to canonical format (AAC-LC .m4a, mono, 44.1kHz, 64kbps).
/// Handles both live recording and normalization of existing files.
class AudioEncoderManager {
    
    // MARK: - Canonical Format Constants
    
    /// Canonical container format: MPEG-4 (.m4a)
    static let canonicalContainerFormat = AVFileType.m4a
    
    /// Canonical codec: AAC-LC (kAudioFormatMPEG4AAC)
    
    /// Canonical sample rate: 44,100 Hz
    static let canonicalSampleRate: Double = 44100.0
    
    /// Canonical channel count: Mono (1 channel)
    static let canonicalChannelCount: UInt32 = 1
    
    /// Canonical bitrate: 64,000 bits/sec (64 kbps)
    static let canonicalBitrate: Int = 64000
    
    /// Maximum recording duration: 60 minutes (in seconds)
    static let maxDurationSeconds: Double = 3600.0
    
    /// Maximum file size estimate: 50 MB (in bytes)
    static let maxFileSizeBytes: Int64 = 50 * 1024 * 1024
    
    // MARK: - Properties
    
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioConverter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var canonicalFormat: AVAudioFormat?
    private var outputURL: URL?
    private var totalFrames: Int64 = 0
    private var startTime: CMTime?
    private let encodingQueue = DispatchQueue(label: "com.reactnativedictation.audioEncoder")
    private let writerQueue = DispatchQueue(label: "com.reactnativedictation.audioEncoder.writer")
    
    /// Called when the live recording duration limit is reached.
    var durationLimitReachedHandler: (() -> Void)?
    private var didNotifyDurationLimit = false
    
    // MARK: - Logging
    
    private func log(_ message: String, level: LogLevel = .info) {
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
        let logMessage = "[\(timestamp)] [AudioEncoderManager] [\(level.rawValue)] \(message)"
        print(logMessage)
        NSLog("%@", logMessage)
    }
    
    private enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }
    
    // MARK: - Recording Pipeline
    
    /// Starts recording to canonical format using direct AAC encoding.
    /// - Parameters:
    ///   - outputURL: Destination file URL (must have .m4a extension)
    ///   - sourceFormat: Format of incoming audio buffers
    /// - Throws: Encoding errors
    func startRecording(outputURL: URL, sourceFormat: AVAudioFormat) throws {
        log("=== START RECORDING ===", level: .info)
        log("Output URL: \(outputURL.path)", level: .info)
        log("Source format: sampleRate=\(sourceFormat.sampleRate), channels=\(sourceFormat.channelCount)", level: .info)
        
        // Validate output URL has .m4a extension
        guard outputURL.pathExtension.lowercased() == "m4a" else {
            throw EncodingError.invalidOutputFormat("Output file must have .m4a extension")
        }
        
        // Ensure directory exists
        let directoryURL = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        self.outputURL = outputURL
        self.sourceFormat = sourceFormat
        didNotifyDurationLimit = false
        
        // Create canonical format (mono, 44.1kHz) for conversion
        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioEncoderManager.canonicalSampleRate,
            channels: AudioEncoderManager.canonicalChannelCount,
            interleaved: false
        ) else {
            throw EncodingError.formatCreationFailed("Failed to create canonical audio format")
        }
        
        self.canonicalFormat = canonicalFormat
        
        // Create audio converter if source format differs
        if sourceFormat.sampleRate != canonicalFormat.sampleRate ||
           sourceFormat.channelCount != canonicalFormat.channelCount {
            guard let converter = AVAudioConverter(from: sourceFormat, to: canonicalFormat) else {
                throw EncodingError.formatCreationFailed("Failed to create audio converter")
            }
            self.audioConverter = converter
            log("Created audio converter: \(sourceFormat.sampleRate)Hz/\(sourceFormat.channelCount)ch -> \(canonicalFormat.sampleRate)Hz/\(canonicalFormat.channelCount)ch", level: .info)
        }
        
        // Create AVAssetWriter for direct AAC encoding
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
            
            // Configure writer input for AAC-LC, mono, 44.1kHz, 64kbps
            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: AudioEncoderManager.canonicalSampleRate,
                AVNumberOfChannelsKey: AudioEncoderManager.canonicalChannelCount,
                AVEncoderBitRateKey: AudioEncoderManager.canonicalBitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            
            guard writer.canAdd(input) else {
                throw EncodingError.writerCreationFailed("Cannot add audio input to writer")
            }
            
            writer.add(input)
            
            // Start writing (session will be started when first sample is appended)
            guard writer.startWriting() else {
                if let error = writer.error {
                    throw EncodingError.writerCreationFailed("Failed to start writing: \(error.localizedDescription)")
                }
                throw EncodingError.writerCreationFailed("Failed to start writing: unknown error")
            }
            
            self.assetWriter = writer
            self.writerInput = input
            self.startTime = nil // Will be set when first sample is appended
            
            log("AVAssetWriter created and started for direct AAC encoding", level: .info)
            
        } catch {
            throw EncodingError.writerCreationFailed("Failed to create AVAssetWriter: \(error.localizedDescription)")
        }
        
        totalFrames = 0
        
        log("Recording started successfully with direct AAC encoding", level: .info)
    }
    
    /// Appends an audio buffer to the recording.
    /// - Parameter buffer: Audio buffer to encode
    func append(_ buffer: AVAudioPCMBuffer) {
        encodingQueue.async { [weak self] in
            guard let self = self,
                  let writerInput = self.writerInput,
                  let assetWriter = self.assetWriter else {
                return
            }
            
            // Check duration limit
            let durationSeconds = Double(self.totalFrames) / AudioEncoderManager.canonicalSampleRate
            if durationSeconds >= AudioEncoderManager.maxDurationSeconds {
                if !self.didNotifyDurationLimit {
                    self.didNotifyDurationLimit = true
                    self.log("Recording duration limit reached (60 minutes)", level: .warning)
                    DispatchQueue.main.async { [weak self] in
                        self?.durationLimitReachedHandler?()
                    }
                }
                return
            }
            
            // Convert buffer if needed
            let bufferToEncode: AVAudioPCMBuffer
            if let converter = self.audioConverter {
                // Convert to canonical format
                guard let convertedBuffer = self.convertBuffer(buffer, using: converter) else {
                    self.log("Failed to convert buffer, skipping", level: .error)
                    return
                }
                bufferToEncode = convertedBuffer
            } else {
                bufferToEncode = buffer
            }
            
            // Convert PCM buffer to CMSampleBuffer for AVAssetWriter
            guard let sampleBuffer = self.createSampleBuffer(from: bufferToEncode) else {
                self.log("Failed to create sample buffer, skipping", level: .error)
                return
            }
            
            // Append to writer on writer queue
            self.writerQueue.async {
                guard writerInput.isReadyForMoreMediaData else {
                    self.log("Writer input not ready, skipping buffer", level: .warning)
                    return
                }
                
                // Start session if not already started (must happen before first append)
                if self.startTime == nil {
                    assetWriter.startSession(atSourceTime: .zero)
                    self.startTime = .zero
                    self.log("Started AVAssetWriter session", level: .info)
                }
                
                // Append sample buffer
                if writerInput.append(sampleBuffer) {
                    self.totalFrames += Int64(bufferToEncode.frameLength)
                } else {
                    if let error = assetWriter.error {
                        self.log("Failed to append sample buffer: \(error.localizedDescription)", level: .error)
                    } else {
                        self.log("Failed to append sample buffer: unknown error", level: .error)
                    }
                }
            }
        }
    }
    
    /// Stops recording and finalizes the file.
    /// - Returns: Result metadata or nil if recording failed
    func stopRecording() -> EncodingResult? {
        return encodingQueue.sync { [weak self] in
            guard let self = self,
                  let assetWriter = self.assetWriter,
                  let writerInput = self.writerInput,
                  let finalURL = self.outputURL else {
                // Clean up if writer wasn't initialized
                self?.cleanup()
                return nil
            }
            
            log("=== STOP RECORDING ===", level: .info)
            
            // Finalize writer synchronously
            let semaphore = DispatchSemaphore(value: 0)
            var finalizeError: Error?
            
            writerQueue.async {
                writerInput.markAsFinished()
                
                assetWriter.finishWriting { [weak self] in
                    if let error = assetWriter.error {
                        finalizeError = error
                        self?.log("Writer finalization error: \(error.localizedDescription)", level: .error)
                    } else {
                        self?.log("Writer finalized successfully", level: .info)
                    }
                    semaphore.signal()
                }
            }
            
            // Wait for finalization (with timeout)
            let timeout = semaphore.wait(timeout: .now() + 30.0)
            if timeout == .timedOut {
                log("Timeout waiting for writer finalization", level: .error)
                self.cleanup()
                return nil
            }
            
            if let error = finalizeError {
                log("Recording failed during finalization: \(error.localizedDescription)", level: .error)
                // Clean up failed file
                try? FileManager.default.removeItem(at: finalURL)
                self.cleanup()
                return nil
            }
            
            // Get file metadata
            guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
                  let fileSize = fileAttributes[.size] as? Int64 else {
                log("Failed to get file attributes", level: .error)
                self.cleanup()
                return nil
            }
            
            let durationSeconds = Double(self.totalFrames) / AudioEncoderManager.canonicalSampleRate
            let durationMs = durationSeconds * 1000.0
            
            let result = EncodingResult(
                fileURL: finalURL,
                durationMs: durationMs,
                fileSizeBytes: fileSize,
                sampleRate: AudioEncoderManager.canonicalSampleRate,
                channelCount: Int(AudioEncoderManager.canonicalChannelCount)
            )
            
            // Validate file size
            if result.fileSizeBytes > AudioEncoderManager.maxFileSizeBytes {
                log("Warning: File size (\(result.fileSizeBytes) bytes) exceeds target (50 MB)", level: .warning)
            }
            
            log("Recording completed: duration=\(result.durationMs)ms, size=\(result.fileSizeBytes)bytes", level: .info)
            
            self.cleanup()
            
            return result
        }
    }
    
    private func cleanup() {
        self.assetWriter = nil
        self.writerInput = nil
        self.audioConverter = nil
        self.sourceFormat = nil
        self.canonicalFormat = nil
        self.outputURL = nil
        self.startTime = nil
        self.totalFrames = 0
    }
    
    // MARK: - Normalization Pipeline
    
    /// Normalizes an existing audio file to canonical format.
    /// - Parameter sourcePath: Path to source audio file
    /// - Returns: Result containing canonical file path and metadata
    /// - Throws: Normalization errors
    func normalizeAudio(sourcePath: String) async throws -> NormalizedAudioResult {
        log("=== NORMALIZE AUDIO ===", level: .info)
        log("Source path: \(sourcePath)", level: .info)
        
        // Validate source file exists
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw NormalizationError.fileNotFound("Source file not found: \(sourcePath)")
        }
        
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let sourceAsset = AVURLAsset(url: sourceURL)
        
        // Load asset properties
        let duration = try await loadDuration(of: sourceAsset)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // Check duration limit
        if durationSeconds > AudioEncoderManager.maxDurationSeconds {
            throw NormalizationError.durationTooLong("Input duration (\(durationSeconds)s) exceeds maximum (3600s)")
        }
        
        // Load audio track
        let audioTracks = try await loadAudioTracks(from: sourceAsset)
        guard let audioTrack = audioTracks.first else {
            throw NormalizationError.unsupportedFormat("No audio track found in source file")
        }
        
        // Check if already canonical
        let formatDescriptions = try await loadFormatDescriptions(for: audioTrack)
        if let formatDescription = formatDescriptions.first {
            if isCanonicalFormat(
                formatDescription: formatDescription,
                audioTrack: audioTrack,
                durationSeconds: durationSeconds
            ) {
                log("Input is already canonical format, using fast-path copy", level: .info)
                return try await fastPathCopy(sourceURL: sourceURL)
            }
        }
        
        // Generate output URL
        let outputURL = generateCanonicalFileURL()
        
        // Transcode to canonical format
        log("Transcoding to canonical format...", level: .info)
        let result = try await transcodeToCanonical(
            sourceAsset: sourceAsset,
            audioTrack: audioTrack,
            outputURL: outputURL
        )
        
        log("Normalization completed: duration=\(result.durationMs)ms, size=\(result.sizeBytes)bytes, wasReencoded=\(result.wasReencoded)", level: .info)
        
        return result
    }
    
    // MARK: - Helper Methods
    
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard let canonicalFormat = canonicalFormat else { return nil }
        
        // Calculate output buffer size
        let inputSampleRate = buffer.format.sampleRate
        let outputSampleRate = canonicalFormat.sampleRate
        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: canonicalFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }
        
        // Convert
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            log("Buffer conversion error: \(error.localizedDescription)", level: .error)
            return nil
        }
        
        return outputBuffer
    }
    
    /// Converts an AVAudioPCMBuffer to a CMSampleBuffer for AVAssetWriter.
    private func createSampleBuffer(from pcmBuffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        guard let canonicalFormat = canonicalFormat else { return nil }
        
        let numSamples = pcmBuffer.frameLength
        guard numSamples > 0 else { return nil }
        
        // Create audio format description
        var formatDescription: CMAudioFormatDescription?
        var audioStreamBasicDescription = AudioStreamBasicDescription(
            mSampleRate: canonicalFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kLinearPCMFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: canonicalFormat.channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &audioStreamBasicDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let formatDesc = formatDescription else {
            log("Failed to create audio format description", level: .error)
            return nil
        }
        
        // Create block buffer from PCM data
        guard let channelData = pcmBuffer.floatChannelData else {
            log("Failed to get channel data from buffer", level: .error)
            return nil
        }
        
        let channelSize = Int(numSamples) * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        
        let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: channelSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: channelSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard blockBufferStatus == noErr, let blockBuf = blockBuffer else {
            log("Failed to create block buffer", level: .error)
            return nil
        }
        
        // Copy audio data to block buffer
        let status2 = CMBlockBufferReplaceDataBytes(
            with: channelData.pointee,
            blockBuffer: blockBuf,
            offsetIntoDestination: 0,
            dataLength: channelSize
        )
        
        guard status2 == noErr else {
            log("Failed to copy data to block buffer", level: .error)
            return nil
        }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleCount = CMItemCount(numSamples)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(canonicalFormat.sampleRate)),
            presentationTimeStamp: CMTime(value: Int64(totalFrames), timescale: Int32(canonicalFormat.sampleRate)),
            decodeTimeStamp: CMTime.invalid
        )
        
        let sampleBufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            formatDescription: formatDesc,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleBufferStatus == noErr, let sampleBuf = sampleBuffer else {
            log("Failed to create sample buffer", level: .error)
            return nil
        }
        
        return sampleBuf
    }

    private func loadValue<T>(
        for key: String,
        from object: AVAsynchronousKeyValueLoading,
        description: String,
        getter: @escaping () throws -> T
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            object.loadValuesAsynchronously(forKeys: [key]) {
                var error: NSError?
                let status = object.statusOfValue(forKey: key, error: &error)
                switch status {
                case .loaded:
                    do {
                        let value = try getter()
                        continuation.resume(returning: value)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failed, .cancelled:
                    let message = error?.localizedDescription ?? "status=\(status.rawValue)"
                    continuation.resume(throwing: NormalizationError.encoderError("Failed to load \(description): \(message)"))
                default:
                    let message = error?.localizedDescription ?? "status=\(status.rawValue)"
                    continuation.resume(throwing: NormalizationError.encoderError("Unexpected status \(status.rawValue) while loading \(description): \(message)"))
                }
            }
        }
    }

    private func loadDuration(of asset: AVAsset) async throws -> CMTime {
        try await loadValue(
            for: "duration",
            from: asset,
            description: "asset duration"
        ) {
            asset.duration
        }
    }

    private func loadAudioTracks(from asset: AVAsset) async throws -> [AVAssetTrack] {
        try await loadValue(
            for: "tracks",
            from: asset,
            description: "audio tracks"
        ) {
            asset.tracks(withMediaType: .audio)
        }
    }

    private func loadFormatDescriptions(for track: AVAssetTrack) async throws -> [CMFormatDescription] {
        try await loadValue(
            for: "formatDescriptions",
            from: track,
            description: "track format descriptions"
        ) {
            track.formatDescriptions as? [CMFormatDescription] ?? []
        }
    }

    private func isCanonicalFormat(formatDescription: CMFormatDescription, audioTrack: AVAssetTrack, durationSeconds: Double) -> Bool {
        // Check duration
        guard durationSeconds <= AudioEncoderManager.maxDurationSeconds else {
            return false
        }
        
        // Get audio stream basic description
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return false
        }
        
        // Check sample rate (must be 44.1kHz)
        guard abs(asbd.pointee.mSampleRate - AudioEncoderManager.canonicalSampleRate) < 1.0 else {
            return false
        }
        
        // Check channel count (must be mono)
        guard asbd.pointee.mChannelsPerFrame == AudioEncoderManager.canonicalChannelCount else {
            return false
        }
        
        // Check format ID (must be AAC)
        guard asbd.pointee.mFormatID == kAudioFormatMPEG4AAC else {
            return false
        }
        
        // For AAC, check if estimated bitrate is within tolerance (±10%)
        let estimatedBitrate = Int(audioTrack.estimatedDataRate.rounded())
        let minBitrate = Int(Double(AudioEncoderManager.canonicalBitrate) * 0.9)
        let maxBitrate = Int(Double(AudioEncoderManager.canonicalBitrate) * 1.1)
        guard estimatedBitrate >= minBitrate && estimatedBitrate <= maxBitrate else {
            return false
        }
        
        return true
    }
    
    private func fastPathCopy(sourceURL: URL) async throws -> NormalizedAudioResult {
        let outputURL = generateCanonicalFileURL()
        
        // Copy file
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        
        // Get metadata
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let fileSize = fileAttributes[.size] as? Int64 else {
            throw NormalizationError.ioError("Failed to get file attributes")
        }
        
        let sourceAsset = AVURLAsset(url: sourceURL)
        let duration = try await loadDuration(of: sourceAsset)
        let durationSeconds = CMTimeGetSeconds(duration)
        let durationMs = durationSeconds * 1000.0
        
        return NormalizedAudioResult(
            canonicalPath: outputURL.path,
            durationMs: durationMs,
            sizeBytes: fileSize,
            wasReencoded: false
        )
    }
    
    private func transcodeToCanonical(
        sourceAsset: AVURLAsset,
        audioTrack: AVAssetTrack,
        outputURL: URL
    ) async throws -> NormalizedAudioResult {
        // Create reader
        guard let reader = try? AVAssetReader(asset: sourceAsset) else {
            throw NormalizationError.encoderError("Failed to create AVAssetReader")
        }
        
        // Configure reader output
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: AudioEncoderManager.canonicalSampleRate,
                AVNumberOfChannelsKey: AudioEncoderManager.canonicalChannelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true
            ]
        )
        
        guard reader.canAdd(readerOutput) else {
            throw NormalizationError.encoderError("Cannot add reader output")
        }
        
        reader.add(readerOutput)
        
        // Create writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .m4a) else {
            throw NormalizationError.encoderError("Failed to create AVAssetWriter")
        }
        
        // Configure writer input
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: AudioEncoderManager.canonicalSampleRate,
                AVNumberOfChannelsKey: AudioEncoderManager.canonicalChannelCount,
                AVEncoderBitRateKey: AudioEncoderManager.canonicalBitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        
        writerInput.expectsMediaDataInRealTime = false
        
        guard writer.canAdd(writerInput) else {
            throw NormalizationError.encoderError("Cannot add writer input")
        }
        
        writer.add(writerInput)
        
        // Start reading and writing
        guard reader.startReading() else {
            if let error = reader.error {
                throw NormalizationError.encoderError("Failed to start reading: \(error.localizedDescription)")
            }
            throw NormalizationError.encoderError("Failed to start reading: unknown error")
        }
        
        guard writer.startWriting() else {
            if let error = writer.error {
                throw NormalizationError.encoderError("Failed to start writing: \(error.localizedDescription)")
            }
            throw NormalizationError.encoderError("Failed to start writing: unknown error")
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // Process samples
        let processingQueue = DispatchQueue(label: "com.reactnativedictation.transcode")
        let semaphore = DispatchSemaphore(value: 0)
        var transcodeError: Error?
        var isFinished = false
        
        writerInput.requestMediaDataWhenReady(on: processingQueue) {
            while writerInput.isReadyForMoreMediaData && !isFinished {
                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                    writerInput.markAsFinished()
                    isFinished = true
                    semaphore.signal()
                    return
                }
                
                if !writerInput.append(sampleBuffer) {
                    if let error = writer.error {
                        transcodeError = error
                    }
                    writerInput.markAsFinished()
                    isFinished = true
                    semaphore.signal()
                    return
                }
            }
        }
        
        // Wait for completion (with timeout)
        let timeout = semaphore.wait(timeout: .now() + 300.0) // 5 minute timeout
        if timeout == .timedOut {
            writerInput.markAsFinished()
            writer.cancelWriting()
            throw NormalizationError.encoderError("Transcoding timed out")
        }
        
        // Finalize
        let finalizeSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finalizeSemaphore.signal()
        }
        
        // Wait for finalization (with timeout)
        let finalizeTimeout = finalizeSemaphore.wait(timeout: .now() + 30.0)
        if finalizeTimeout == .timedOut {
            throw NormalizationError.encoderError("Finalization timed out")
        }
        
        if let error = transcodeError ?? writer.error {
            try? FileManager.default.removeItem(at: outputURL)
            throw NormalizationError.encoderError("Transcoding failed: \(error.localizedDescription)")
        }
        
        // Get result metadata
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let fileSize = fileAttributes[.size] as? Int64 else {
            throw NormalizationError.ioError("Failed to get file attributes")
        }
        
        let duration = try await loadDuration(of: sourceAsset)
        let durationSeconds = CMTimeGetSeconds(duration)
        let durationMs = durationSeconds * 1000.0
        
        return NormalizedAudioResult(
            canonicalPath: outputURL.path,
            durationMs: durationMs,
            sizeBytes: fileSize,
            wasReencoded: true
        )
    }
    
    private func generateCanonicalFileURL() -> URL {
        return CanonicalAudioStorage.makeRecordingURL()
    }
}

// MARK: - Result Types

struct EncodingResult {
    let fileURL: URL
    let durationMs: Double
    let fileSizeBytes: Int64
    let sampleRate: Double
    let channelCount: Int
}

struct NormalizedAudioResult {
    let canonicalPath: String
    let durationMs: Double
    let sizeBytes: Int64
    let wasReencoded: Bool
}

// MARK: - Error Types

enum EncodingError: Error {
    case invalidOutputFormat(String)
    case formatCreationFailed(String)
    case writerCreationFailed(String)
    
    var code: String {
        switch self {
        case .invalidOutputFormat:
            return "encoding_invalid_output"
        case .formatCreationFailed:
            return "encoding_format_failed"
        case .writerCreationFailed:
            return "encoding_writer_failed"
        }
    }
    
    var localizedDescription: String {
        switch self {
        case .invalidOutputFormat(let message):
            return "Invalid output format: \(message)"
        case .formatCreationFailed(let message):
            return "Format creation failed: \(message)"
        case .writerCreationFailed(let message):
            return "Writer creation failed: \(message)"
        }
    }
}

enum NormalizationError: Error {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case durationTooLong(String)
    case ioError(String)
    case encoderError(String)
    
    var code: String {
        switch self {
        case .fileNotFound:
            return "file_not_found"
        case .unsupportedFormat:
            return "unsupported_format"
        case .durationTooLong:
            return "duration_too_long"
        case .ioError:
            return "io_error"
        case .encoderError:
            return "encoder_error"
        }
    }
    
    var localizedDescription: String {
        switch self {
        case .fileNotFound(let message):
            return "File not found: \(message)"
        case .unsupportedFormat(let message):
            return "Unsupported format: \(message)"
        case .durationTooLong(let message):
            return "Duration too long: \(message)"
        case .ioError(let message):
            return "I/O error: \(message)"
        case .encoderError(let message):
            return "Encoder error: \(message)"
        }
    }
}
