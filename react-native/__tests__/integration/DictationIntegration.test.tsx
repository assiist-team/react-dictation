import React from 'react';
import { render, waitFor, act, renderHook, waitFor as waitForHook } from '@testing-library/react-native';

// Mock react-native-svg before importing src to avoid React Native API dependencies
jest.mock('react-native-svg', () => ({
  Svg: 'Svg',
  Rect: 'Rect',
  Circle: 'Circle',
  Path: 'Path',
  G: 'G',
  Defs: 'Defs',
  LinearGradient: 'LinearGradient',
  Stop: 'Stop',
}));

import { useDictation, useWaveform } from '../../src';

// Mock native modules
const mockListeners: Record<string, Array<(event: any) => void>> = {};
const mockEmit = (event: string, data: any) => {
  mockListeners[event]?.forEach(cb => cb(data));
};

// Mock react-native without requiring actual module to avoid Babel Flow parsing issues
jest.mock('react-native', () => {
  const mockEmitterInstance = {
    addListener: jest.fn((event: string, callback: (event: any) => void) => {
      if (!mockListeners[event]) {
        mockListeners[event] = [];
      }
      mockListeners[event].push(callback);
      return {
        remove: jest.fn(() => {
          const index = mockListeners[event]?.indexOf(callback);
          if (index !== undefined && index >= 0) {
            mockListeners[event].splice(index, 1);
          }
        }),
      };
    }),
  };

  return {
    NativeModules: {
      DictationModule: {
        initialize: jest.fn().mockResolvedValue(undefined),
        startListening: jest.fn().mockResolvedValue(undefined),
        stopListening: jest.fn().mockResolvedValue(undefined),
        cancelListening: jest.fn().mockResolvedValue(undefined),
        getAudioLevel: jest.fn().mockResolvedValue(0.5),
        normalizeAudio: jest.fn().mockResolvedValue({
          canonicalPath: '/path/to/normalized.m4a',
          durationMs: 5000,
          sizeBytes: 40000,
          wasReencoded: false,
        }),
      },
    },
    NativeEventEmitter: jest.fn().mockImplementation(() => mockEmitterInstance),
    Platform: { 
      OS: 'ios',
      select: jest.fn((obj) => obj.ios || obj.default),
      Version: 17,
    },
    processColor: jest.fn((color) => color),
    StyleSheet: {
      create: jest.fn((styles) => styles),
      flatten: jest.fn(),
      hairlineWidth: 0.5,
    },
    View: (props: any) => React.createElement('View', props),
    Text: (props: any) => React.createElement('Text', props),
    ScrollView: (props: any) => React.createElement('ScrollView', props),
    Touchable: {
      Mixin: {
        touchableHandleStartShouldSetResponder: jest.fn(),
        touchableHandleResponderTerminationRequest: jest.fn(),
        touchableHandleResponderGrant: jest.fn(),
        touchableHandleResponderMove: jest.fn(),
        touchableHandleResponderRelease: jest.fn(),
        touchableHandleResponderTerminate: jest.fn(),
      },
    },
    TouchableOpacity: 'TouchableOpacity',
    TouchableHighlight: 'TouchableHighlight',
    TouchableWithoutFeedback: 'TouchableWithoutFeedback',
    TextInput: 'TextInput',
    Image: 'Image',
  };
});

// Mock NativeDictationModule
jest.mock('../../src/NativeDictationModule', () => {
  const mockEmitterInstance = {
    addListener: jest.fn((event: string, callback: (event: any) => void) => {
      if (!mockListeners[event]) {
        mockListeners[event] = [];
      }
      mockListeners[event].push(callback);
      return {
        remove: jest.fn(() => {
          const index = mockListeners[event]?.indexOf(callback);
          if (index !== undefined && index >= 0) {
            mockListeners[event].splice(index, 1);
          }
        }),
      };
    }),
  };

  const { NativeModules } = require('react-native');
  
  return {
    DictationEventEmitter: mockEmitterInstance,
    NativeDictationModule: NativeModules.DictationModule,
    DictationEvents: {
      onResult: 'onResult',
      onStatus: 'onStatus',
      onAudioLevel: 'onAudioLevel',
      onAudioFile: 'onAudioFile',
      onError: 'onError',
    },
  };
});

// Test component that uses hooks
function TestDictationComponent({ 
  onInitialized,
  onResult,
}: { 
  onInitialized?: () => void;
  onResult?: (text: string) => void;
}) {
  const dictation = useDictation({
    onFinalResult: (text) => {
      onResult?.(text);
    },
  });
  const waveform = useWaveform();

  React.useEffect(() => {
    dictation.initialize().then(() => {
      onInitialized?.();
    });
  }, []);

  React.useEffect(() => {
    if (dictation.isListening && dictation.audioLevel > 0) {
      waveform.updateLevel(dictation.audioLevel);
    }
  }, [dictation.audioLevel, dictation.isListening]);

  return null;
}

describe('Dictation Integration', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    // Clear mock listeners
    Object.keys(mockListeners).forEach(key => delete mockListeners[key]);
  });

  it('should initialize and be ready', async () => {
    let initialized = false;
    
    const { result } = renderHook(() => {
      const dictation = useDictation();
      
      React.useEffect(() => {
        dictation.initialize().then(() => {
          initialized = true;
        });
      }, []);

      return dictation;
    });

    await waitFor(() => expect(initialized).toBe(true), { timeout: 5000 });
    expect(result.current.isInitialized).toBe(true);
  });

  it('should integrate waveform with dictation audio levels', async () => {
    let initialized = false;
    const { result: hookResult } = renderHook(() => {
      const dictation = useDictation();
      const waveform = useWaveform({ bufferSize: 10 });
      
      React.useEffect(() => {
        dictation.initialize().then(() => {
          initialized = true;
        });
      }, []);

      React.useEffect(() => {
        if (dictation.audioLevel > 0) {
          waveform.updateLevel(dictation.audioLevel);
        }
      }, [dictation.audioLevel]);

      return { dictation, waveform };
    });

    await waitForHook(() => expect(initialized).toBe(true));

    // Start listening to set up event listeners
    await act(async () => {
      await hookResult.current.dictation.startListening();
    });

    // Simulate audio level update via event emitter (event structure matches DictationAudioLevel type)
    act(() => {
      mockEmit('onAudioLevel', { level: 0.75 });
    });

    await waitForHook(() => {
      expect(hookResult.current.dictation.audioLevel).toBe(0.75);
      expect(hookResult.current.waveform.currentLevel).toBeGreaterThan(0);
    });
  });

  it('should handle start listening flow', async () => {
    const { NativeModules } = require('react-native');
    const onResult = jest.fn();
    
    const { result } = renderHook(() => {
      const dictation = useDictation({
        onFinalResult: onResult,
      });
      
      React.useEffect(() => {
        dictation.initialize();
      }, []);

      return dictation;
    });

    await waitFor(() => {
      expect(NativeModules.DictationModule.initialize).toHaveBeenCalled();
      expect(result.current.isInitialized).toBe(true);
    });
  });
});
