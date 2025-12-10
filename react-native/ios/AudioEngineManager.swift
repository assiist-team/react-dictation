import AVFoundation
import AudioToolbox
import Foundation
import UIKit

protocol AudioEngineManagerDelegate: AnyObject {
    func audioEngineManagerDidHitDurationLimit(_ manager: AudioEngineManager)
    func audioEngineManager(_ manager: AudioEngineManager, didEncounterEncodingError error: Error)
}

/// Manages AVAudioEngine for low-latency audio recording and waveform visualization.
/// Provides real-time audio buffer access with optimal configuration for speech recognition.
///
/// NOTE: This file is largely unchanged from the Flutter version.
/// It is framework-agnostic and works identically in React Native.
class AudioEngineManager {
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    
    /// Exposes the audio engine for speech recognizer attachment.
    var engine: AVAudioEngine {
        return audioEngine
    }

    private func notifyDurationLimitReached() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioEngineManagerDidHitDurationLimit(self)
        }
    }
    
    private var inputNode: AVAudioInputNode {
        return audioEngine.inputNode
    }
    
    private var bufferCallback: ((AVAudioPCMBuffer) -> Void)?
    private var currentAudioLevel: Float = 0.0
    private var state: AudioEngineState = .idle
    private var bufferCount: Int = 0
    private var isSessionActivated: Bool = false
    private var audioEncoderManager: AudioEncoderManager?
    private var pendingAudioBuffers: [AVAudioPCMBuffer] = []
    private let bufferQueue = DispatchQueue(label: "com.reactnativedictation.audioEngine.bufferQueue")
    
    weak var delegate: AudioEngineManagerDelegate?
    
    // Audio level smoothing for waveform visualization
    private let levelSmoothingFactor: Float = 0.3
    
    // Thread-safe audio level access
    private let audioLevelQueue = DispatchQueue(label: "com.reactnativedictation.audioLevel")
    
    // MARK: - State Management
    
    enum AudioEngineState {
        case idle
        case recording
        case stopped
    }
    
    // MARK: - Initialization
    
    /// Initializes the audio engine with optimal low-latency configuration.
    /// Note: Audio session category is not set here to avoid requiring permissions during init.
    func initialize() throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        log("=== INITIALIZE START ===")
        
        guard state == .idle else {
            log("Already initialized, state: \(state)")
            return
        }
        
        let engineStartTime = CFAbsoluteTimeGetCurrent()
        log("Setting up audio engine...")
        do {
            try setupAudioEngine()
            let engineDuration = (CFAbsoluteTimeGetCurrent() - engineStartTime) * 1000
            log("Audio engine setup completed in \(String(format: "%.2f", engineDuration))ms")
        } catch {
            let engineDuration = (CFAbsoluteTimeGetCurrent() - engineStartTime) * 1000
            log("Audio engine setup FAILED after \(String(format: "%.2f", engineDuration))ms: \(error)")
            throw error
        }
        
        log("Setting up interruption handling...")
        setupInterruptionHandling()
        
        state = .idle
        
        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("=== INITIALIZE COMPLETE in \(String(format: "%.2f", totalDuration))ms ===")
    }
    
    // MARK: - Audio Session Configuration
    
    private func configureAudioSession() throws {
        try audioSession.setCategory(.record, mode: .measurement, options: [])
        try audioSession.setPreferredIOBufferDuration(0.005) // 5ms buffer
        try audioSession.setPreferredSampleRate(44100)
        try audioSession.setActive(true)
    }
    
    // MARK: - Audio Engine Setup
    
    private func safePrepareAudioEngine(_ engine: AVAudioEngine) throws {
        engine.prepare()
    }
    
    private func setupAudioEngine() throws {
        #if targetEnvironment(simulator)
        log("Running on simulator - deferring audio engine prepare")
        return
        #endif
    }
    
    @MainActor
    private func checkMicrophonePermission() -> Bool {
        return audioSession.recordPermission == .granted
    }
    
    @MainActor
    private func requestMicrophonePermission() async -> Bool {
        let currentStatus = audioSession.recordPermission
        
        log("Requesting microphone permission. Current status: \(currentStatus)")
        
        if currentStatus == .granted {
            return true
        }
        
        if currentStatus == .denied {
            log("Permission already denied")
            return false
        }
        
        return await withCheckedContinuation { continuation in
            self.audioSession.requestRecordPermission { granted in
                self.log("Permission request result: \(granted)")
                continuation.resume(returning: granted)
            }
        }
    }
    
    @MainActor
    private func prepareAudioEngineWithPermissionCheck() throws {
        let permissionStatus = audioSession.recordPermission
        
        switch permissionStatus {
        case .undetermined:
            throw NSError(
                domain: "AudioEngineManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Microphone permission not yet requested."
                ]
            )
        case .denied:
            throw NSError(
                domain: "AudioEngineManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Microphone permission denied. Please grant access in Settings."
                ]
            )
        case .granted:
            break
        @unknown default:
            throw NSError(
                domain: "AudioEngineManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unknown microphone permission status."
                ]
            )
        }
        
        try safePrepareAudioEngine(audioEngine)
    }
    
    private func installAudioTap() {
        inputNode.removeTap(onBus: 0)
        
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
    }
    
    // MARK: - Recording Control
    
    @MainActor
    func startRecording(audioPreservationRequest: AudioPreservationRequest? = nil) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        log("=== START RECORDING ===")
        log("Current state: \(state)")
        
        guard state != .recording else {
            log("Already recording")
            return
        }
        
        if audioEngine.isRunning {
            log("Stopping existing audio engine...")
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
        }
        
        // Set audio session category
        log("Setting audio session category...")
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
        } catch {
            log("FAILED to set category: \(error)")
            throw NSError(
                domain: "AudioEngineManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to set audio session category: \(error.localizedDescription)"]
            )
        }
        
        // Check/request permission
        log("Checking microphone permission...")
        let permissionStatus = audioSession.recordPermission
        
        if permissionStatus != .granted {
            let granted = await requestMicrophonePermission()
            guard audioSession.recordPermission == .granted else {
                throw NSError(
                    domain: "AudioEngineManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."]
                )
            }
        }
        
        // Configure audio session
        do {
            try audioSession.setPreferredIOBufferDuration(0.005)
            try audioSession.setPreferredSampleRate(44100)
        } catch {
            throw NSError(
                domain: "AudioEngineManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to configure audio session: \(error.localizedDescription)"]
            )
        }
        
        // Activate session
        if !isSessionActivated {
            do {
                try audioSession.setActive(true)
                isSessionActivated = true
            } catch {
                throw NSError(
                    domain: "AudioEngineManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to activate audio session: \(error.localizedDescription)"]
                )
            }
        }
        
        // Prepare audio engine
        try prepareAudioEngineWithPermissionCheck()
        
        // Install tap
        installAudioTap()
        
        // Start engine
        do {
            try audioEngine.start()
            log("Audio engine started successfully")
            
            // Setup audio preservation if requested
            if let preservationRequest = audioPreservationRequest {
                try startAudioPreservationIfNeeded(request: preservationRequest)
                flushPendingBuffers()
            }
        } catch {
            throw NSError(
                domain: "AudioEngineManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine failed to start: \(error.localizedDescription)"]
            )
        }
        
        state = .recording
        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("=== START RECORDING COMPLETE in \(String(format: \"%.2f\", totalDuration))ms ===")
    }
    
    @discardableResult
    func stopRecording(deletePreservedAudio: Bool = false) -> AudioPreservationResult? {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        inputNode.removeTap(onBus: 0)
        
        bufferQueue.sync {
            self.pendingAudioBuffers.removeAll()
        }
        
        audioLevelQueue.sync {
            self.currentAudioLevel = 0.0
        }
        
        state = .stopped
        return stopAudioPreservation(deleteFile: deletePreservedAudio)
    }
    
    // MARK: - Audio Preservation
    
    private func startAudioPreservationIfNeeded(request: AudioPreservationRequest) throws {
        guard audioEncoderManager == nil else {
            return
        }
        
        let format = inputNode.inputFormat(forBus: 0)
        
        var outputURL = request.fileURL
        if outputURL.pathExtension.lowercased() != "m4a" {
            outputURL = outputURL.deletingPathExtension().appendingPathExtension("m4a")
        }
        
        let encoder = AudioEncoderManager()
        encoder.durationLimitReachedHandler = { [weak self] in
            self?.notifyDurationLimitReached()
        }
        
        do {
            try encoder.startRecording(outputURL: outputURL, sourceFormat: format)
            audioEncoderManager = encoder
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioEngineManager(self, didEncounterEncodingError: error)
            }
            throw error
        }
    }
    
    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: buffer.format.commonFormat,
            sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount,
            interleaved: buffer.format.isInterleaved
        ) else { return nil }
        
        guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        
        bufferCopy.frameLength = buffer.frameLength
        
        if let srcChannelData = buffer.floatChannelData,
           let dstChannelData = bufferCopy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstChannelData[channel], srcChannelData[channel],
                       Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        }
        
        return bufferCopy
    }
    
    private func flushPendingBuffers() {
        bufferQueue.sync {
            guard let encoder = self.audioEncoderManager else {
                self.pendingAudioBuffers.removeAll()
                return
            }
            
            for buffer in self.pendingAudioBuffers {
                encoder.append(buffer)
            }
            self.pendingAudioBuffers.removeAll()
        }
    }
    
    private func stopAudioPreservation(deleteFile: Bool) -> AudioPreservationResult? {
        guard let encoder = audioEncoderManager else { return nil }
        
        let encodingResult = encoder.stopRecording()
        audioEncoderManager = nil
        
        if deleteFile {
            if let result = encodingResult {
                try? FileManager.default.removeItem(at: result.fileURL)
            }
            return nil
        }
        
        guard let result = encodingResult else { return nil }
        
        return AudioPreservationResult(
            fileURL: result.fileURL,
            durationMs: result.durationMs,
            fileSizeBytes: result.fileSizeBytes,
            sampleRate: result.sampleRate,
            channelCount: result.channelCount
        )
    }
    
    // MARK: - Buffer Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        
        guard state == .recording else { return }
        
        let newLevel = calculateAudioLevel(from: buffer)
        
        audioLevelQueue.sync {
            self.currentAudioLevel = self.currentAudioLevel * (1.0 - self.levelSmoothingFactor) +
                                     newLevel * self.levelSmoothingFactor
        }
        
        if let encoder = audioEncoderManager {
            encoder.append(buffer)
        } else if state == .recording {
            bufferQueue.sync {
                if let bufferCopy = copyBuffer(buffer) {
                    self.pendingAudioBuffers.append(bufferCopy)
                    // Limit queue size
                    let maxFrames = Int(44100 * 0.5)
                    var totalFrames = 0
                    while totalFrames < maxFrames && !self.pendingAudioBuffers.isEmpty {
                        totalFrames += Int(self.pendingAudioBuffers.first!.frameLength)
                        if totalFrames >= maxFrames {
                            self.pendingAudioBuffers.removeFirst()
                        } else {
                            break
                        }
                    }
                }
            }
        }
        
        bufferCallback?(buffer)
    }
    
    // MARK: - Audio Level Calculation
    
    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }
        
        let channelDataPointer = channelData.pointee
        
        var sumOfSquares: Float = 0.0
        var peakSample: Float = 0.0
        
        for frameIndex in 0..<frameLength {
            let sample = channelDataPointer[frameIndex]
            sumOfSquares += sample * sample
            peakSample = max(peakSample, abs(sample))
        }
        
        let rms = sqrt(sumOfSquares / Float(frameLength))
        let dbLevel = 20 * log10(max(rms, 1e-10))
        
        let minimumDecibels: Float = -75.0
        let maximumDecibels: Float = -15.0
        let clampedDbLevel = min(max(dbLevel, minimumDecibels), maximumDecibels)
        let normalizedDecibelLevel = (clampedDbLevel - minimumDecibels) / (maximumDecibels - minimumDecibels)
        
        let linearGain: Float = 4.0
        let normalizedRmsLevel = min(rms * linearGain, 1.0)
        let normalizedPeakLevel = min(peakSample * linearGain, 1.0)
        
        let blendedLevel = (normalizedDecibelLevel * 0.55) +
                          (normalizedRmsLevel * 0.30) +
                          (normalizedPeakLevel * 0.15)
        
        let amplitudeShapeExponent: Float = 1.2
        let shapedLevel = powf(blendedLevel, amplitudeShapeExponent)
        
        return max(0.0, min(1.0, shapedLevel))
    }
    
    func getAudioLevel() -> Float {
        return audioLevelQueue.sync { self.currentAudioLevel }
    }
    
    // MARK: - Buffer Callback
    
    func setBufferCallback(_ callback: @escaping (AVAudioPCMBuffer) -> Void) {
        bufferCallback = callback
    }
    
    func removeBufferCallback() {
        bufferCallback = nil
    }
    
    // MARK: - Interruption Handling
    
    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    @objc private func handleAppDidEnterBackground(_ notification: Notification) {
        isSessionActivated = false
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            isSessionActivated = false
            if state == .recording {
                audioEngine.pause()
            }
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && state == .recording {
                    do {
                        if !isSessionActivated {
                            try audioSession.setActive(true)
                            isSessionActivated = true
                        }
                        try audioEngine.start()
                    } catch {
                        log("Failed to resume after interruption: \(error)")
                        state = .stopped
                    }
                }
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        if reason == .oldDeviceUnavailable && state == .recording {
            stopRecording()
        }
    }
    
    // MARK: - Cleanup
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        inputNode.removeTap(onBus: 0)
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
        let logMessage = "[\(timestamp)] [AudioEngineManager] \(message)"
        print(logMessage)
        #if DEBUG
        NSLog("%@", logMessage)
        #endif
    }
    
    // MARK: - State Queries
    
    var isRecording: Bool { state == .recording }
    var isRunning: Bool { audioEngine.isRunning }
}
