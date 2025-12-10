import { DictationService } from '../../src/DictationService';
import { NativeModules, NativeEventEmitter } from 'react-native';

// Mock native modules
jest.mock('react-native', () => ({
  NativeModules: {
    DictationModule: {
      initialize: jest.fn().mockImplementation(() => 
        new Promise(resolve => setTimeout(resolve, 200))
      ),
      startListening: jest.fn().mockResolvedValue(undefined),
      stopListening: jest.fn().mockResolvedValue(undefined),
      getAudioLevel: jest.fn().mockResolvedValue(0.5),
    },
  },
  NativeEventEmitter: jest.fn().mockImplementation(() => ({
    addListener: jest.fn().mockReturnValue({ remove: jest.fn() }),
  })),
  Platform: { OS: 'ios' },
}));

/**
 * Performance benchmarks for dictation service.
 * These tests measure latency targets as specified in the testing plan.
 */
describe('Dictation Performance Benchmarks', () => {
  let service: DictationService;

  beforeEach(() => {
    jest.clearAllMocks();
    service = new DictationService();
  });

  afterEach(() => {
    service.dispose();
  });

  describe('Latency Targets', () => {
    it('should initialize within 500ms', async () => {
      const initStart = performance.now();
      await service.initialize();
      const initLatency = performance.now() - initStart;
      
      console.log(`Initialize latency: ${initLatency.toFixed(2)}ms`);
      expect(initLatency).toBeLessThan(500);
    });

    it('should start listening within 100ms', async () => {
      await service.initialize();
      
      const startTime = performance.now();
      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
      });
      const startLatency = performance.now() - startTime;
      
      console.log(`Start listening latency: ${startLatency.toFixed(2)}ms`);
      expect(startLatency).toBeLessThan(100);
    });

    it('should get audio level within 50ms', async () => {
      await service.initialize();
      
      const levelStart = performance.now();
      await service.getAudioLevel();
      const levelLatency = performance.now() - levelStart;
      
      console.log(`Audio level latency: ${levelLatency.toFixed(2)}ms`);
      expect(levelLatency).toBeLessThan(50);
    });

    it('should stop listening within 200ms', async () => {
      await service.initialize();
      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
      });
      
      const stopStart = performance.now();
      await service.stopListening();
      const stopLatency = performance.now() - stopStart;
      
      console.log(`Stop latency: ${stopLatency.toFixed(2)}ms`);
      expect(stopLatency).toBeLessThan(200);
    });
  });

  describe('Memory Benchmarks', () => {
    it('should track memory usage during recording', async () => {
      // performance.memory is only available in Chrome/Chromium browsers, not in Node.js
      // Skip this test in Node.js test environment
      if (typeof (performance as any).memory === 'undefined') {
        // Skip on environments without memory API
        return;
      }

      const initialMemory = (performance as any).memory.usedJSHeapSize;
      
      await service.initialize();
      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
      });

      // Simulate 5 seconds of recording
      await new Promise(resolve => setTimeout(resolve, 100));

      const recordingMemory = (performance as any).memory.usedJSHeapSize;
      const memoryDelta = recordingMemory - initialMemory;
      
      console.log(`Memory delta during recording: ${(memoryDelta / 1024 / 1024).toFixed(2)} MB`);
      
      await service.stopListening();
      await service.dispose();
    });
  });
});

/**
 * Standalone benchmark function for manual testing
 */
export async function runLatencyBenchmark() {
  const service = new DictationService();
  
  try {
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
        if (!firstResultTime && !isFinal) {
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
  } finally {
    service.dispose();
  }
}
