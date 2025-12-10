import React from 'react';
import { render, waitFor, act, renderHook, waitFor as waitForHook } from '@testing-library/react-native';
import { useDictation, useWaveform } from '../../src';

// Mock native modules
const mockListeners: Record<string, Array<(event: any) => void>> = {};
const mockEmit = (event: string, data: any) => {
  mockListeners[event]?.forEach(cb => cb(data));
};

jest.mock('react-native', () => {
  const actualRN = jest.requireActual('react-native');
  return {
    ...actualRN,
    NativeModules: {
      DictationModule: {
        initialize: jest.fn().mockResolvedValue(undefined),
        startListening: jest.fn().mockResolvedValue(undefined),
        stopListening: jest.fn().mockResolvedValue(undefined),
        cancelListening: jest.fn().mockResolvedValue(undefined),
        getAudioLevel: jest.fn().mockResolvedValue(0.5),
      },
    },
    NativeEventEmitter: jest.fn().mockImplementation(() => {
      return {
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
    }),
    Platform: { OS: 'ios' },
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
    
    render(
      <TestDictationComponent 
        onInitialized={() => { initialized = true; }} 
      />
    );

    await waitFor(() => expect(initialized).toBe(true), { timeout: 5000 });
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

    // Simulate audio level update via event emitter
    act(() => {
      mockEmit('onAudioLevel', { level: 0.75 });
    });

    await waitForHook(() => {
      expect(hookResult.current.waveform.currentLevel).toBeGreaterThan(0);
    });
  });

  it('should handle start listening flow', async () => {
    const { NativeModules } = require('react-native');
    const onResult = jest.fn();
    
    render(
      <TestDictationComponent onResult={onResult} />
    );

    await waitFor(() => {
      expect(NativeModules.DictationModule.initialize).toHaveBeenCalled();
    });
  });
});
