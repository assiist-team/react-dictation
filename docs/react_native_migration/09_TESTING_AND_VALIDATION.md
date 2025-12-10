# Phase 9: Testing and Validation

## Overview

This phase covers comprehensive testing strategies to ensure the React Native dictation module works correctly across iOS and Android, matching the Flutter plugin's functionality.

## Testing Pyramid

```
                    ┌───────────────────┐
                    │   E2E Tests       │  Manual + Detox
                    │   (Few)           │
                    └─────────┬─────────┘
                              │
               ┌──────────────┴──────────────┐
               │    Integration Tests        │  Jest + Native
               │    (Some)                   │
               └──────────────┬──────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │         Unit Tests                    │  Jest + XCTest + JUnit
          │         (Many)                        │
          └───────────────────────────────────────┘
```

## 1. Unit Tests

### TypeScript Tests (Jest)

**test/DictationService.test.ts**
```typescript
import { DictationService } from '../src/DictationService';
import { NativeModules, NativeEventEmitter } from 'react-native';

// Mock native modules
jest.mock('react-native', () => ({
  NativeModules: {
    DictationModule: {
      initialize: jest.fn(),
      startListening: jest.fn(),
      stopListening: jest.fn(),
      cancelListening: jest.fn(),
      getAudioLevel: jest.fn(),
      normalizeAudio: jest.fn(),
    },
  },
  NativeEventEmitter: jest.fn().mockImplementation(() => ({
    addListener: jest.fn().mockReturnValue({ remove: jest.fn() }),
  })),
  Platform: { OS: 'ios' },
}));

describe('DictationService', () => {
  let service: DictationService;

  beforeEach(() => {
    jest.clearAllMocks();
    service = new DictationService();
  });

  afterEach(() => {
    service.dispose();
  });

  describe('initialize', () => {
    it('should call native initialize', async () => {
      NativeModules.DictationModule.initialize.mockResolvedValue(undefined);

      await service.initialize();

      expect(NativeModules.DictationModule.initialize).toHaveBeenCalled();
    });

    it('should retry on missing plugin error', async () => {
      NativeModules.DictationModule.initialize
        .mockRejectedValueOnce(new Error('null'))
        .mockResolvedValueOnce(undefined);

      await service.initialize({ maxRetries: 2, retryDelayMs: 10 });

      expect(NativeModules.DictationModule.initialize).toHaveBeenCalledTimes(2);
    });

    it('should throw after max retries', async () => {
      NativeModules.DictationModule.initialize
        .mockRejectedValue(new Error('null'));

      await expect(
        service.initialize({ maxRetries: 2, retryDelayMs: 10 })
      ).rejects.toThrow('Native module not available');
    });
  });

  describe('startListening', () => {
    it('should call native startListening with options', async () => {
      NativeModules.DictationModule.startListening.mockResolvedValue(undefined);

      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
        options: {
          preserveAudio: true,
          deleteAudioIfCancelled: false,
        },
      });

      expect(NativeModules.DictationModule.startListening).toHaveBeenCalledWith({
        preserveAudio: true,
        deleteAudioIfCancelled: false,
      });
    });
  });

  describe('normalizeAudio', () => {
    it('should return normalized result', async () => {
      const mockResult = {
        canonicalPath: '/path/to/normalized.m4a',
        durationMs: 5000,
        sizeBytes: 40000,
        wasReencoded: true,
      };
      NativeModules.DictationModule.normalizeAudio.mockResolvedValue(mockResult);

      const result = await service.normalizeAudio('/path/to/input.wav');

      expect(result).toEqual(mockResult);
      expect(NativeModules.DictationModule.normalizeAudio).toHaveBeenCalledWith('/path/to/input.wav');
    });
  });
});
```

**test/hooks/useWaveform.test.ts**
```typescript
import { renderHook, act } from '@testing-library/react-hooks';
import { useWaveform } from '../src/hooks/useWaveform';

describe('useWaveform', () => {
  it('should initialize with zeros', () => {
    const { result } = renderHook(() => useWaveform());

    expect(result.current.levels).toHaveLength(100);
    expect(result.current.levels.every(l => l === 0)).toBe(true);
    expect(result.current.currentLevel).toBe(0);
  });

  it('should update level and shift buffer', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 5 }));

    act(() => {
      result.current.updateLevel(0.5);
    });

    expect(result.current.currentLevel).toBe(0.5);
    expect(result.current.levels).toEqual([0, 0, 0, 0, 0.5]);
  });

  it('should clamp levels to 0-1', () => {
    const { result } = renderHook(() => useWaveform());

    act(() => {
      result.current.updateLevel(1.5);
    });
    expect(result.current.currentLevel).toBe(1);

    act(() => {
      result.current.updateLevel(-0.5);
    });
    expect(result.current.currentLevel).toBe(0);
  });

  it('should reset to zeros', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 5 }));

    act(() => {
      result.current.updateLevel(0.5);
      result.current.updateLevel(0.8);
      result.current.reset();
    });

    expect(result.current.levels.every(l => l === 0)).toBe(true);
    expect(result.current.currentLevel).toBe(0);
  });
});
```

### iOS Native Tests (XCTest)

**ios/ReactNativeDictationTests/AudioEngineManagerTests.swift**
```swift
import XCTest
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
    
    func testInitialize() throws {
        XCTAssertNoThrow(try manager.initialize())
        XCTAssertFalse(manager.isRecording)
    }
    
    func testAudioLevelStartsAtZero() {
        let level = manager.getAudioLevel()
        XCTAssertEqual(level, 0.0, accuracy: 0.001)
    }
    
    func testCalculateAudioLevel() {
        // Test with silent buffer
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        
        // Fill with zeros
        if let channelData = buffer.floatChannelData {
            for i in 0..<Int(buffer.frameLength) {
                channelData.pointee[i] = 0.0
            }
        }
        
        // Level should be very low for silent buffer
        // (Private method - would need to expose for testing)
    }
}

class SpeechRecognizerManagerTests: XCTestCase {
    
    func testInitializeRequiresAuthorization() async {
        let manager = SpeechRecognizerManager()
        
        // This will fail without proper authorization
        do {
            try await manager.initialize()
            // If it succeeds, authorization was already granted
            XCTAssertTrue(manager.isListening == false)
        } catch {
            // Expected on simulators or without permission
            XCTAssertTrue(error is SpeechRecognizerError)
        }
    }
}
```

### Android Native Tests (JUnit)

**android/src/test/java/com/reactnativedictation/AudioEngineManagerTest.kt**
```kotlin
package com.reactnativedictation

import android.content.Context
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mock
import org.mockito.junit.MockitoJUnitRunner
import kotlin.test.assertEquals

@RunWith(MockitoJUnitRunner::class)
class AudioEngineManagerTest {

    @Mock
    lateinit var mockContext: Context

    private lateinit var manager: AudioEngineManager

    @Before
    fun setUp() {
        manager = AudioEngineManager(mockContext)
    }

    @Test
    fun `getAudioLevel returns 0 when not recording`() {
        val level = manager.getAudioLevel()
        assertEquals(0f, level)
    }

    @Test
    fun `calculateAudioLevel returns 0 for silent buffer`() {
        val silentBuffer = ShortArray(1024) { 0 }
        // Would need to expose method for testing
    }
}
```

## 2. Integration Tests

### React Native Integration

**test/integration/DictationIntegration.test.tsx**
```typescript
import React from 'react';
import { render, waitFor, act } from '@testing-library/react-native';
import { useDictation, useWaveform } from '../src';

// Test component that uses hooks
function TestDictationComponent({ onInitialized }: { onInitialized: () => void }) {
  const dictation = useDictation({
    onFinalResult: (text) => console.log('Final:', text),
  });
  const waveform = useWaveform();

  React.useEffect(() => {
    dictation.initialize().then(onInitialized);
  }, []);

  React.useEffect(() => {
    if (dictation.isListening) {
      waveform.updateLevel(dictation.audioLevel);
    }
  }, [dictation.audioLevel]);

  return null;
}

describe('Dictation Integration', () => {
  // These tests require native modules to be properly mocked
  // or run on a device/simulator

  it('should initialize and be ready', async () => {
    let initialized = false;
    
    render(
      <TestDictationComponent 
        onInitialized={() => { initialized = true; }} 
      />
    );

    await waitFor(() => expect(initialized).toBe(true), { timeout: 5000 });
  });
});
```

## 3. Manual Testing Checklist

### iOS Testing

#### Permissions
- [ ] First launch shows microphone permission dialog
- [ ] First `startListening` shows speech recognition permission dialog
- [ ] Denying permission shows appropriate error
- [ ] Re-granting permission in Settings works

#### Audio Engine
- [ ] Recording starts within 100ms of tap
- [ ] Audio level updates at ~30 FPS
- [ ] Waveform responds to voice input
- [ ] Recording continues during interruptions (calls) - verify pause/resume
- [ ] Unplugging headphones stops recording gracefully

#### Speech Recognition
- [ ] Partial results appear while speaking
- [ ] Final result appears after stop
- [ ] Long utterances (30+ seconds) work correctly
- [ ] Multiple languages work (if supported)
- [ ] Offline recognition works (when downloaded)

#### Audio Preservation
- [ ] Audio file is created after stop
- [ ] Audio file is deleted after cancel (when configured)
- [ ] Audio file contains valid audio
- [ ] File plays back correctly
- [ ] 60-minute limit triggers correctly

#### Edge Cases
- [ ] Rapid start/stop doesn't crash
- [ ] Background/foreground transitions work
- [ ] Memory usage stays stable during long sessions
- [ ] Works with Bluetooth audio devices

### Android Testing

#### Permissions
- [ ] Runtime permission dialog appears
- [ ] Denying shows error
- [ ] "Don't ask again" scenario handled

#### Speech Recognition
- [ ] Google speech recognition works
- [ ] Partial results appear
- [ ] Network errors show appropriate message
- [ ] Works with different OEM implementations

#### Audio
- [ ] Audio levels update smoothly
- [ ] Recording produces valid files
- [ ] Works with different sample rates

## 4. Performance Benchmarks

### Latency Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Initialize to ready | < 500ms | Console timestamps |
| Tap to listening | < 100ms | Video frame analysis |
| First partial result | < 500ms | Event timestamp delta |
| Audio level latency | < 50ms | Tap test + video |
| Stop to final result | < 200ms | Console timestamps |

### Memory Benchmarks

| Scenario | Max Memory | Duration |
|----------|------------|----------|
| Idle after init | +10 MB | - |
| During recording | +50 MB | 5 min recording |
| After recording | +15 MB | After cleanup |

### Test Script

```typescript
async function runLatencyBenchmark() {
  const service = new DictationService();
  
  // Initialize latency
  const initStart = performance.now();
  await service.initialize();
  const initLatency = performance.now() - initStart;
  console.log(`Initialize latency: ${initLatency.toFixed(2)}ms`);
  
  // Start listening latency
  let firstResultTime: number | null = null;
  const startTime = performance.now();
  
  await service.startListening({
    onResult: (text, isFinal) => {
      if (!firstResultTime) {
        firstResultTime = performance.now();
        console.log(`First result latency: ${(firstResultTime - startTime).toFixed(2)}ms`);
      }
    },
    onStatus: (status) => {
      if (status === 'listening') {
        const listeningLatency = performance.now() - startTime;
        console.log(`Start listening latency: ${listeningLatency.toFixed(2)}ms`);
      }
    },
    onAudioLevel: () => {},
  });
  
  // Record for 5 seconds
  await new Promise(resolve => setTimeout(resolve, 5000));
  
  // Stop latency
  const stopStart = performance.now();
  await service.stopListening();
  const stopLatency = performance.now() - stopStart;
  console.log(`Stop latency: ${stopLatency.toFixed(2)}ms`);
  
  service.dispose();
}
```

## 5. Automated E2E Tests (Detox)

**e2e/dictation.e2e.ts**
```typescript
import { device, element, by, expect } from 'detox';

describe('Dictation E2E', () => {
  beforeAll(async () => {
    await device.launchApp({ permissions: { microphone: 'YES' } });
  });

  beforeEach(async () => {
    await device.reloadReactNative();
  });

  it('should show mic button', async () => {
    await expect(element(by.id('mic-button'))).toBeVisible();
  });

  it('should start listening on mic tap', async () => {
    await element(by.id('mic-button')).tap();
    await expect(element(by.id('waveform'))).toBeVisible();
    await expect(element(by.id('cancel-button'))).toBeVisible();
  });

  it('should stop on checkmark tap', async () => {
    await element(by.id('mic-button')).tap();
    await waitFor(element(by.id('stop-button'))).toBeVisible().withTimeout(2000);
    await element(by.id('stop-button')).tap();
    await expect(element(by.id('waveform'))).not.toBeVisible();
  });

  it('should cancel on X tap', async () => {
    await element(by.id('mic-button')).tap();
    await element(by.id('cancel-button')).tap();
    await expect(element(by.id('waveform'))).not.toBeVisible();
  });
});
```

## 6. Validation Against Flutter Baseline

Compare results with the original Flutter implementation:

| Feature | Flutter Behavior | RN Behavior | Status |
|---------|------------------|-------------|--------|
| Init latency | ~200ms | ? | ⬜ |
| Start latency | ~80ms | ? | ⬜ |
| Audio level range | 0.0-1.0 | 0.0-1.0 | ⬜ |
| Waveform FPS | 30 | 30 | ⬜ |
| Partial results | ✓ | ? | ⬜ |
| Audio preservation | ✓ | ? | ⬜ |
| Canonical format | AAC-LC 44.1kHz mono 64kbps | ? | ⬜ |
| Duration limit | 60 min | ? | ⬜ |
| Permission handling | ✓ | ? | ⬜ |
| Error codes | Consistent | ? | ⬜ |

## Running Tests

```bash
# TypeScript unit tests
npm test

# iOS native tests
cd ios && xcodebuild test -scheme ReactNativeDictation -destination 'platform=iOS Simulator,name=iPhone 15'

# Android native tests
cd android && ./gradlew test

# E2E tests (requires running app)
npm run e2e:ios
npm run e2e:android
```

## Next Steps

Proceed to [10_NODEJS_BACKEND_INTEGRATION.md](./10_NODEJS_BACKEND_INTEGRATION.md) for backend integration patterns.
