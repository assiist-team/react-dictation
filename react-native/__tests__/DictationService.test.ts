import { DictationService } from '../src/DictationService';

// Initialize global mocks storage before any jest.mock() calls
// This ensures mocks are available to all mock factories regardless of hoisting order
if (!(global as any).__dictationMocks__) {
  (global as any).__dictationMocks__ = {};
}

// Mock native modules first - define mocks inside factory to avoid hoisting issues
jest.mock('react-native', () => {
  // Create mocks inside the factory function
  const mockInitialize = jest.fn();
  const mockStartListening = jest.fn();
  const mockStopListening = jest.fn();
  const mockCancelListening = jest.fn();
  const mockGetAudioLevel = jest.fn();
  const mockNormalizeAudio = jest.fn();
  const mockAddListener = jest.fn().mockReturnValue({ remove: jest.fn() });
  const mockEmitter = { addListener: mockAddListener };
  
  // Store references for later access in tests and other mocks
  (global as any).__dictationMocks__ = {
    mockInitialize,
    mockStartListening,
    mockStopListening,
    mockCancelListening,
    mockGetAudioLevel,
    mockNormalizeAudio,
    mockAddListener,
    mockEmitter,
  };
  
  return {
    NativeModules: {
      DictationModule: {
        initialize: mockInitialize,
        startListening: mockStartListening,
        stopListening: mockStopListening,
        cancelListening: mockCancelListening,
        getAudioLevel: mockGetAudioLevel,
        normalizeAudio: mockNormalizeAudio,
      },
    },
    NativeEventEmitter: jest.fn().mockImplementation(() => mockEmitter),
    Platform: { OS: 'ios' },
  };
});

// Mock the NativeDictationModule to use the same mocks
jest.mock('../src/NativeDictationModule', () => {
  // Get or create mocks from global storage
  let storedMocks = (global as any).__dictationMocks__;
  
  // If mocks haven't been created yet (can happen due to hoisting order),
  // create them here as well
  if (!storedMocks || !storedMocks.mockEmitter) {
    const mockInitialize = jest.fn();
    const mockStartListening = jest.fn();
    const mockStopListening = jest.fn();
    const mockCancelListening = jest.fn();
    const mockGetAudioLevel = jest.fn();
    const mockNormalizeAudio = jest.fn();
    const mockAddListener = jest.fn().mockReturnValue({ remove: jest.fn() });
    const mockEmitter = { addListener: mockAddListener };
    
    storedMocks = {
      mockInitialize,
      mockStartListening,
      mockStopListening,
      mockCancelListening,
      mockGetAudioLevel,
      mockNormalizeAudio,
      mockAddListener,
      mockEmitter,
    };
    (global as any).__dictationMocks__ = storedMocks;
  }
  
  return {
    DictationEventEmitter: storedMocks.mockEmitter,
    NativeDictationModule: {
      initialize: storedMocks.mockInitialize,
      startListening: storedMocks.mockStartListening,
      stopListening: storedMocks.mockStopListening,
      cancelListening: storedMocks.mockCancelListening,
      getAudioLevel: storedMocks.mockGetAudioLevel,
      normalizeAudio: storedMocks.mockNormalizeAudio,
    },
    DictationEvents: {
      onResult: 'onResult',
      onStatus: 'onStatus',
      onAudioLevel: 'onAudioLevel',
      onAudioFile: 'onAudioFile',
      onError: 'onError',
    },
  };
});

// Store mocks reference for use in tests
let mocks: {
  mockInitialize: jest.Mock;
  mockStartListening: jest.Mock;
  mockStopListening: jest.Mock;
  mockCancelListening: jest.Mock;
  mockGetAudioLevel: jest.Mock;
  mockNormalizeAudio: jest.Mock;
  mockAddListener: jest.Mock;
  mockEmitter: { addListener: jest.Mock };
};

describe('DictationService', () => {
  let service: DictationService;

  beforeEach(() => {
    // Get mocks from global storage (set up in jest.mock factories)
    mocks = (global as any).__dictationMocks__;
    if (!mocks) {
      throw new Error('Mocks not initialized');
    }
    jest.clearAllMocks();
    mocks.mockAddListener.mockReturnValue({ remove: jest.fn() });
    service = new DictationService();
  });

  afterEach(() => {
    service.dispose();
  });

  describe('initialize', () => {
    it('should call native initialize', async () => {
      mocks.mockInitialize.mockResolvedValue(undefined);

      await service.initialize();

      expect(mocks.mockInitialize).toHaveBeenCalled();
    });

    it('should call native initialize with locale', async () => {
      mocks.mockInitialize.mockResolvedValue(undefined);

      await service.initialize({ locale: 'en-US' });

      expect(mocks.mockInitialize).toHaveBeenCalledWith({ locale: 'en-US' });
    });

    it('should retry on missing plugin error', async () => {
      mocks.mockInitialize
        .mockRejectedValueOnce(new Error('null'))
        .mockResolvedValueOnce(undefined);

      await service.initialize({ maxRetries: 2, retryDelayMs: 10 });

      expect(mocks.mockInitialize).toHaveBeenCalledTimes(2);
    });

    it('should throw after max retries', async () => {
      mocks.mockInitialize.mockRejectedValue(new Error('null'));

      await expect(
        service.initialize({ maxRetries: 2, retryDelayMs: 10 })
      ).rejects.toThrow('Native module not available');
    });

    it('should not retry on non-module errors', async () => {
      const error = new Error('Permission denied');
      mocks.mockInitialize.mockRejectedValue(error);

      await expect(service.initialize()).rejects.toThrow('Permission denied');
      expect(mocks.mockInitialize).toHaveBeenCalledTimes(1);
    });
  });

  describe('startListening', () => {
    beforeEach(async () => {
      mocks.mockInitialize.mockResolvedValue(undefined);
      await service.initialize();
    });

    it('should call native startListening with options', async () => {
      mocks.mockStartListening.mockResolvedValue(undefined);

      const onResult = jest.fn();
      const onStatus = jest.fn();
      const onAudioLevel = jest.fn();

      await service.startListening({
        onResult,
        onStatus,
        onAudioLevel,
        options: {
          preserveAudio: true,
          deleteAudioIfCancelled: false,
        },
      });

      expect(mocks.mockStartListening).toHaveBeenCalledWith({
        preserveAudio: true,
        deleteAudioIfCancelled: false,
      });
    });

    it('should set up event listeners', async () => {
      mocks.mockStartListening.mockResolvedValue(undefined);

      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
      });

      expect(mocks.mockAddListener).toHaveBeenCalledTimes(4); // onResult, onStatus, onAudioLevel, onError
    });

    it('should handle onAudioFile callback when provided', async () => {
      mocks.mockStartListening.mockResolvedValue(undefined);

      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
        onAudioFile: jest.fn(),
      });

      expect(mocks.mockAddListener).toHaveBeenCalledTimes(5); // Includes onAudioFile
    });
  });

  describe('stopListening', () => {
    it('should call native stopListening', async () => {
      mocks.mockStopListening.mockResolvedValue(undefined);

      await service.stopListening();

      expect(mocks.mockStopListening).toHaveBeenCalled();
    });
  });

  describe('cancelListening', () => {
    it('should call native cancelListening', async () => {
      mocks.mockCancelListening.mockResolvedValue(undefined);

      await service.cancelListening();

      expect(mocks.mockCancelListening).toHaveBeenCalled();
    });
  });

  describe('getAudioLevel', () => {
    it('should return audio level from native module', async () => {
      const mockLevel = 0.75;
      mocks.mockGetAudioLevel.mockResolvedValue(mockLevel);

      const level = await service.getAudioLevel();

      expect(level).toBe(mockLevel);
      expect(mocks.mockGetAudioLevel).toHaveBeenCalled();
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
      mocks.mockNormalizeAudio.mockResolvedValue(mockResult);

      const result = await service.normalizeAudio('/path/to/input.wav');

      expect(result).toEqual(mockResult);
      expect(mocks.mockNormalizeAudio).toHaveBeenCalledWith('/path/to/input.wav');
    });
  });

  describe('dispose', () => {
    it('should remove all subscriptions', async () => {
      mocks.mockInitialize.mockResolvedValue(undefined);
      mocks.mockStartListening.mockResolvedValue(undefined);

      await service.initialize();
      await service.startListening({
        onResult: jest.fn(),
        onStatus: jest.fn(),
        onAudioLevel: jest.fn(),
      });

      const subscriptions = mocks.mockAddListener.mock.results.map((r: any) => r.value);
      
      service.dispose();

      subscriptions.forEach((sub: { remove: jest.Mock }) => {
        expect(sub.remove).toHaveBeenCalled();
      });
    });
  });
});
