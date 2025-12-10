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
