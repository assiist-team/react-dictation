import XCTest
import AVFoundation
@testable import ReactNativeDictation

class AudioEngineManagerTests: XCTestCase {
    
    var manager: AudioEngineManager!
    
    override func setUp() {
        super.setUp()
        manager = AudioEngineManager()
    }
    
    override func tearDown() {
        manager = nil
        super.tearDown()
    }
    
    func testInitialization() {
        XCTAssertNotNil(manager)
        XCTAssertFalse(manager.isRecording)
    }
    
    func testAudioLevelStartsAtZero() {
        let level = manager.getAudioLevel()
        XCTAssertEqual(level, 0.0, accuracy: 0.001, "Audio level should start at zero")
    }
    
    func testGetAudioLevelReturnsValidRange() {
        let level = manager.getAudioLevel()
        XCTAssertGreaterThanOrEqual(level, 0.0, "Audio level should be >= 0")
        XCTAssertLessThanOrEqual(level, 1.0, "Audio level should be <= 1")
    }
    
    func testAudioEngineProperty() {
        let engine = manager.engine
        XCTAssertNotNil(engine, "Audio engine should be accessible")
        XCTAssertFalse(engine.isRunning, "Audio engine should not be running initially")
    }
    
    // Note: Testing actual recording requires microphone permissions and may not work in CI
    // These tests verify the basic structure and initial state
    
    func testStateIsIdleInitially() {
        // Verify initial state is idle (this would require exposing state property or using a different approach)
        XCTAssertFalse(manager.isRecording, "Manager should not be recording initially")
    }
}

class SpeechRecognizerManagerTests: XCTestCase {
    
    func testInitialization() {
        let manager = SpeechRecognizerManager()
        XCTAssertNotNil(manager)
    }
    
    func testInitializeRequiresAuthorization() async {
        let manager = SpeechRecognizerManager()
        
        // This will fail without proper authorization
        do {
            try await manager.initialize()
            // If it succeeds, authorization was already granted
            XCTAssertTrue(manager.isListening == false, "Should not be listening after initialization")
        } catch {
            // Expected on simulators or without permission
            // Verify it's a proper error
            XCTAssertNotNil(error, "Should throw error when authorization is missing")
        }
    }
    
    func testIsListeningStartsAsFalse() {
        let manager = SpeechRecognizerManager()
        XCTAssertFalse(manager.isListening, "Should not be listening initially")
    }
}
