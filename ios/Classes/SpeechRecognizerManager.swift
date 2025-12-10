import AVFoundation
import Foundation
import Speech

/// Manages SFSpeechRecognizer for low-latency speech recognition.
/// Provides real-time partial results integrated with the audio engine.
class SpeechRecognizerManager {
    
    // MARK: - Properties
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var resultCallback: ((String, Bool) -> Void)?
    private var statusCallback: ((String) -> Void)?
    
    private var state: RecognitionState = .idle
    private let stateQueue = DispatchQueue(label: "com.flutterdictation.speechRecognizer.state")
    
    private var isAuthorized: Bool = false
    private weak var currentInputNode: AVAudioInputNode?
    private var bufferCount: Int = 0  // Track buffer count for logging
    
    // MARK: - State Management
    
    enum RecognitionState {
        case idle           // Ready but not active
        case initializing   // Starting up
        case listening      // Actively recognizing
        case processing     // Finalizing result
        case stopped        // Stopped, can restart
        case cancelled      // Cancelled, needs reset
    }
    
    // MARK: - Initialization
    
    /// Initializes the speech recognizer with optimal configuration for dictation.
    /// Should be called at app launch for pre-warming.
    /// - Throws: Initialization errors
    func initialize() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Check if already initialized
        if recognizer != nil && isAuthorized {
            return
        }
        
        // Request authorization
        let authStartTime = CFAbsoluteTimeGetCurrent()
        let authorized = await requestAuthorization()
        let authDuration = (CFAbsoluteTimeGetCurrent() - authStartTime) * 1000
        logEvent("authorization_request", metadata: ["duration_ms": authDuration, "authorized": authorized])
        
        guard authorized else {
            throw SpeechRecognizerError.notAuthorized
        }
        
        // Create recognizer with English locale
        let recognizerStartTime = CFAbsoluteTimeGetCurrent()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let recognizerDuration = (CFAbsoluteTimeGetCurrent() - recognizerStartTime) * 1000
        logEvent("recognizer_creation", metadata: ["duration_ms": recognizerDuration])
        
        guard let recognizer = recognizer else {
            throw SpeechRecognizerError.notAvailable
        }
        
        // Configure for dictation (long-form speech)
        recognizer.defaultTaskHint = .dictation
        
        // Enable on-device recognition if available (faster, more private)
        if #available(iOS 13.0, *) {
            recognizer.supportsOnDeviceRecognition = true
        }
        
        // Check availability
        guard recognizer.isAvailable else {
            throw SpeechRecognizerError.notAvailable
        }
        
        isAuthorized = true
        stateQueue.sync {
            self.state = .idle
        }
        
        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logEvent("speech_recognizer_initialize_complete", metadata: ["total_duration_ms": totalDuration])
    }
    
    // MARK: - Authorization
    
    /// Requests speech recognition authorization.
    /// - Returns: True if authorized, false otherwise
    func requestAuthorization() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    // MARK: - Recognition Control
    
    /// Starts speech recognition with the provided audio engine.
    /// Uses shared buffer approach - receives buffers from AudioEngineManager instead of installing its own tap.
    /// AVAudioEngine only supports one tap per bus, so we must share the tap installed by AudioEngineManager.
    /// - Parameter audioEngine: The AVAudioEngine instance (used for format info, but tap is shared via buffer callback)
    /// - Throws: Recognition start errors
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
        let requestStartTime = CFAbsoluteTimeGetCurrent()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        let requestDuration = (CFAbsoluteTimeGetCurrent() - requestStartTime) * 1000
        logEvent("recognition_request_creation", metadata: ["duration_ms": requestDuration])
        
        guard let recognitionRequest = recognitionRequest else {
            stateQueue.sync {
                self.state = .idle
            }
            throw SpeechRecognizerError.requestCreationFailed
        }
        
        // Configure for real-time results
        recognitionRequest.shouldReportPartialResults = true
        
        // Task hint for dictation
        recognitionRequest.taskHint = .dictation
        
        // Note: We do NOT install a tap here because AVAudioEngine only supports ONE tap per bus.
        // AudioEngineManager already installs a tap on bus 0 for waveform visualization.
        // We will receive buffers via setBufferCallback() which is set up by DictationManager.
        // The buffer callback will append buffers to the recognition request.
        let inputNode = audioEngine.inputNode
        currentInputNode = inputNode
        
        // Start recognition task
        let taskStartTime = CFAbsoluteTimeGetCurrent()
        recognitionTask = recognizer.recognitionTask(
            with: recognitionRequest
        ) { [weak self] result, error in
            self?.handleRecognitionResult(result: result, error: error)
        }
        let taskDuration = (CFAbsoluteTimeGetCurrent() - taskStartTime) * 1000
        logEvent("recognition_task_start", metadata: ["duration_ms": taskDuration])
        
        stateQueue.sync {
            self.state = .listening
        }
        
        statusCallback?("listening")
        
        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logEvent("start_recognition_complete", metadata: ["total_duration_ms": totalDuration])
    }
    
    /// Appends an audio buffer to the recognition request.
    /// This is called by AudioEngineManager's buffer callback to share audio buffers.
    /// - Parameter buffer: The audio PCM buffer to append
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Track buffer count for logging
        bufferCount += 1
        
        if bufferCount <= 5 {
            print("[SpeechRecognizerManager] === appendAudioBuffer CALLED (buffer #\(bufferCount)) ===")
            print("[SpeechRecognizerManager] Buffer frameLength: \(buffer.frameLength)")
            print("[SpeechRecognizerManager] Buffer sampleRate: \(buffer.format.sampleRate)")
        }
        
        // Thread-safe state check
        let shouldAppend = stateQueue.sync {
            let currentState = self.state
            if bufferCount <= 5 {
                print("[SpeechRecognizerManager] Current state: \(currentState)")
                print("[SpeechRecognizerManager] Should append: \(currentState == .listening || currentState == .initializing)")
            }
            return currentState == .listening || currentState == .initializing
        }
        guard shouldAppend else {
            if bufferCount <= 5 {
                print("[SpeechRecognizerManager] WARNING: Skipping buffer append - state check failed")
            } else if Int.random(in: 0..<100) == 0 {
                logEvent("buffer_append_skipped", metadata: ["state": "\(stateQueue.sync { self.state })"])
            }
            return
        }
        
        guard let request = recognitionRequest else {
            if bufferCount <= 5 {
                print("[SpeechRecognizerManager] ERROR: recognitionRequest is nil!")
            } else if Int.random(in: 0..<100) == 0 {
                logEvent("buffer_append_failed", metadata: ["reason": "recognitionRequest is nil"])
            }
            return
        }
        
        if bufferCount <= 5 {
            print("[SpeechRecognizerManager] Appending buffer to recognition request...")
        }
        request.append(buffer)
        
        if bufferCount <= 5 {
            print("[SpeechRecognizerManager] Buffer appended successfully")
        }
        
        // Log occasionally to confirm buffers are being received
        if Int.random(in: 0..<1000) == 0 {
            logEvent("buffer_appended", metadata: [
                "frame_length": buffer.frameLength,
                "sample_rate": buffer.format.sampleRate
            ])
        }
    }
    
    /// Stops speech recognition gracefully.
    /// Finalizes the current result and allows restart.
    func stopRecognition() {
        stateQueue.sync {
            guard self.state == .listening || self.state == .initializing else {
                return
            }
            self.state = .processing
        }
        
        // Finish the recognition request (allows final result)
        recognitionRequest?.endAudio()
        
        // Note: We don't remove the tap here because AVAudioEngine only supports one tap per bus.
        // Removing it would also remove the waveform tap if AudioEngineManager is still recording.
        // The tap will stop processing buffers once endAudio() is called, so it's safe to leave it.
        // The tap will be cleaned up when the audio engine stops or when we cancel recognition.
        
        // Wait for final result, then update state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.stateQueue.sync {
                self?.state = .stopped
            }
            self?.statusCallback?("stopped")
        }
    }
    
    /// Cancels speech recognition immediately.
    /// Discards current results and resets state.
    func cancelRecognition() {
        stateQueue.sync {
            guard self.state != .idle && self.state != .cancelled else {
                return
            }
        }
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Finish request to clean up
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Note: We do NOT remove the tap here because AudioEngineManager owns the tap.
        // The tap will be removed when AudioEngineManager stops recording.
        currentInputNode = nil
        
        stateQueue.sync {
            self.state = .cancelled
        }
        
        // Reset to idle after a brief delay, but only if still cancelled
        // (don't overwrite if a new recognition has started)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.stateQueue.sync {
                // Only reset to idle if still cancelled (no new recognition started)
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
            logEvent("recognition_error", metadata: ["error": "\(error)"])
            handleRecognitionError(error)
            return
        }
        
        guard let result = result else {
            logEvent("recognition_result_nil", metadata: [:])
            return
        }
        
        // Track first result latency
        let transcription = result.bestTranscription.formattedString
        logEvent("recognition_result", metadata: [
            "is_final": result.isFinal,
            "text_length": transcription.count,
            "text_preview": transcription.prefix(50)
        ])
        
        if resultCallback != nil {
            logEvent("calling_result_callback", metadata: [
                "is_final": result.isFinal,
                "text_length": transcription.count
            ])
            // Send partial results immediately
            resultCallback?(transcription, result.isFinal)
        } else {
            logEvent("result_callback_is_nil", metadata: [
                "is_final": result.isFinal,
                "text_length": transcription.count
            ])
        }
        
        // Update status
        if result.isFinal {
            stateQueue.sync {
                self.state = .processing
            }
            statusCallback?("done")
            
            // Transition to stopped after final result
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
        
        // Check if it's a Speech framework error by checking error codes
        // Speech framework uses specific error codes regardless of domain
        let errorCode = nsError.code
        
        // Map error codes to known Speech framework errors
        // SFSpeechRecognizerErrorCode values:
        // - 201: notAuthorized
        // - 209: notAvailable
        // - 216: recognitionTaskUnavailable
        switch errorCode {
        case 201: // SFSpeechRecognizerErrorNotAuthorized
            isAuthorized = false
            stateQueue.sync {
                self.state = .idle
            }
            statusCallback?("error:notAuthorized")
            
        case 209: // SFSpeechRecognizerErrorNotAvailable
            stateQueue.sync {
                self.state = .idle
            }
            statusCallback?("error:notAvailable")
            
        case 216: // SFSpeechRecognizerErrorRecognitionTaskUnavailable
            // Retry by resetting state
            stateQueue.sync {
                self.state = .idle
            }
            statusCallback?("error:taskUnavailable")
            
        default:
            // Check if it's likely a Speech framework error by domain
            if nsError.domain.contains("Speech") || nsError.domain.contains("speech") {
                stateQueue.sync {
                    self.state = .stopped
                }
                statusCallback?("error:\(error.localizedDescription)")
            } else {
                // Network or other errors
                stateQueue.sync {
                    self.state = .stopped
                }
                statusCallback?("error:\(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Callbacks
    
    /// Sets a callback to receive recognition results.
    /// - Parameter callback: Closure called with (transcription, isFinal)
    func setResultCallback(_ callback: @escaping (String, Bool) -> Void) {
        resultCallback = callback
    }
    
    /// Sets a callback to receive status updates.
    /// - Parameter callback: Closure called with status string
    func setStatusCallback(_ callback: @escaping (String) -> Void) {
        statusCallback = callback
    }
    
    // MARK: - State Queries
    
    /// Returns whether recognition is currently active.
    var isListening: Bool {
        return stateQueue.sync {
            return self.state == .listening || self.state == .initializing
        }
    }
    
    /// Returns the current recognition state.
    var currentState: RecognitionState {
        return stateQueue.sync {
            return self.state
        }
    }
    
    // MARK: - Logging
    
    /// Logs events with metadata for performance monitoring and debugging.
    /// - Parameters:
    ///   - event: Event name
    ///   - metadata: Additional metadata dictionary
    private func logEvent(_ event: String, metadata: [String: Any] = [:]) {
        #if DEBUG
        let metadataString = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        print("[SpeechRecognizerManager] \(event): \(metadataString)")
        #endif
        // In production, this could send to analytics or crash reporting
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

