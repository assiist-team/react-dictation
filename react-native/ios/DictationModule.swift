import Foundation
import AVFoundation
import React

@objc(DictationModule)
class DictationModule: RCTEventEmitter {
    
    // MARK: - Properties
    
    private var coordinator: DictationCoordinator?
    private var hasListeners = false
    
    // MARK: - Module Setup
    
    override init() {
        super.init()
    }
    
    override func supportedEvents() -> [String]! {
        return [
            "onResult",
            "onStatus",
            "onAudioLevel",
            "onAudioFile",
            "onError"
        ]
    }
    
    override func startObserving() {
        hasListeners = true
    }
    
    override func stopObserving() {
        hasListeners = false
    }
    
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    // MARK: - Bridge Methods
    
    @objc func initialize(
        _ options: NSDictionary?,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        Task { @MainActor in
            do {
                if coordinator == nil {
                    coordinator = DictationCoordinator(eventEmitter: self)
                }
                
                // Parse locale from options (BCP-47 format, e.g., "en-US")
                let locale: Locale
                if let optionsDict = options as? [String: Any],
                   let localeString = optionsDict["locale"] as? String,
                   !localeString.isEmpty {
                    locale = Locale(identifier: localeString)
                } else {
                    locale = Locale.current
                }
                
                try await coordinator?.initialize(locale: locale)
                resolve(nil)
            } catch {
                let dictationError = DictationError.from(error)
                reject(dictationError.code, dictationError.localizedDescription, error)
            }
        }
    }
    
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
    
    func emitResult(text: String, isFinal: Bool) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onResult", body: [
            "text": text,
            "isFinal": isFinal
        ])
    }
    
    func emitStatus(_ status: String) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onStatus", body: [
            "status": status
        ])
    }
    
    func emitAudioLevel(_ level: Float) {
        guard hasListeners else { return }
        
        sendEvent(withName: "onAudioLevel", body: [
            "level": level
        ])
    }
    
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
