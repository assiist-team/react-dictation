# Phase 6: TypeScript Service Layer

## Overview

This phase implements the TypeScript service layer that wraps the native module and provides React hooks for easy integration. This replaces Flutter's `NativeDictationService` Dart class.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ React Components                                                │
│   │                                                             │
│   │  useDictation() hook                                        │
│   │       │                                                     │
│   │       ▼                                                     │
│   │  DictationService                                           │
│   │       │                                                     │
│   └───────┼─────────────────────────────────────────────────────┘
│           │                                                     │
│           ▼                                                     │
│   NativeEventEmitter ◄──── Native Events                        │
│           │                                                     │
│           ▼                                                     │
│   NativeModules.DictationModule                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation

### 1. Type Definitions

**src/types/index.ts**
```typescript
// Session options (matches Flutter DictationSessionOptions)
export interface DictationSessionOptions {
  /** Whether to save the audio to a file */
  preserveAudio?: boolean;
  /** Custom file path (relative to Documents or absolute) */
  preservedAudioFilePath?: string;
  /** Whether to delete the audio file if session is cancelled */
  deleteAudioIfCancelled?: boolean;
}

// Recognition result event
export interface DictationResult {
  text: string;
  isFinal: boolean;
}

// Status values
export type DictationStatusValue =
  | 'ready'
  | 'listening'
  | 'stopped'
  | 'cancelled'
  | 'duration_limit_reached'
  | `error:${string}`;

export interface DictationStatus {
  status: DictationStatusValue;
}

// Audio level event (0.0 - 1.0)
export interface DictationAudioLevel {
  level: number;
}

// Audio file metadata (emitted after recording)
export interface DictationAudioFile {
  path: string;
  durationMs: number;
  fileSizeBytes: number;
  sampleRate: number;
  channelCount: number;
  wasCancelled: boolean;
}

// Error event
export interface DictationError {
  message: string;
  code?: string;
}

// Normalization result
export interface NormalizedAudioResult {
  canonicalPath: string;
  durationMs: number;
  sizeBytes: number;
  wasReencoded: boolean;
}

// Callback types
export type OnResultCallback = (text: string, isFinal: boolean) => void;
export type OnStatusCallback = (status: DictationStatusValue) => void;
export type OnAudioLevelCallback = (level: number) => void;
export type OnAudioFileCallback = (file: DictationAudioFile) => void;
export type OnErrorCallback = (message: string, code?: string) => void;
```

### 2. Native Module Spec

**src/NativeDictationModule.ts**
```typescript
import { NativeModules, NativeEventEmitter, Platform } from 'react-native';
import type { DictationSessionOptions, NormalizedAudioResult } from './types';

// Type for the native module
interface DictationModuleSpec {
  initialize(options?: { locale?: string }): Promise<void>;
  startListening(options?: DictationSessionOptions): Promise<void>;
  stopListening(): Promise<void>;
  cancelListening(): Promise<void>;
  getAudioLevel(): Promise<number>;
  normalizeAudio(sourcePath: string): Promise<NormalizedAudioResult>;
}

// Get the native module
const { DictationModule } = NativeModules;

if (Platform.OS !== 'ios' && Platform.OS !== 'android') {
  console.warn('DictationModule is only available on iOS and Android');
}

// Export typed module
export const NativeDictationModule = DictationModule as DictationModuleSpec;

// Export event emitter
export const DictationEventEmitter = new NativeEventEmitter(DictationModule);

// Event names (must match native supportedEvents())
export const DictationEvents = {
  onResult: 'onResult',
  onStatus: 'onStatus',
  onAudioLevel: 'onAudioLevel',
  onAudioFile: 'onAudioFile',
  onError: 'onError',
} as const;
```

### 3. Dictation Service Class

**src/DictationService.ts**
```typescript
import { EmitterSubscription } from 'react-native';
import {
  NativeDictationModule,
  DictationEventEmitter,
  DictationEvents,
} from './NativeDictationModule';
import type {
  DictationSessionOptions,
  DictationResult,
  DictationStatus,
  DictationAudioLevel,
  DictationAudioFile,
  DictationError,
  NormalizedAudioResult,
  OnResultCallback,
  OnStatusCallback,
  OnAudioLevelCallback,
  OnAudioFileCallback,
  OnErrorCallback,
} from './types';

/**
 * Service for managing native iOS/Android dictation.
 * Provides low-latency speech recognition with real-time results and audio levels.
 */
export class DictationService {
  private subscriptions: EmitterSubscription[] = [];
  private isInitialized = false;

  /**
   * Initialize the native dictation service.
   * Should be called before starting to listen.
   * Retries automatically if native module isn't ready yet.
   * @param options Configuration options including locale (BCP-47 format, e.g., "en-US")
   */
  async initialize(options?: { 
    locale?: string; 
    maxRetries?: number; 
    retryDelayMs?: number 
  }): Promise<void> {
    const { locale, maxRetries = 10, retryDelayMs = 100 } = options ?? {};
    let retryCount = 0;

    while (retryCount < maxRetries) {
      try {
        await NativeDictationModule.initialize(locale ? { locale } : undefined);
        this.isInitialized = true;
        return;
      } catch (error) {
        const errorMessage = String(error);
        
        // Check if it's a "module not found" type error
        if (
          errorMessage.includes('null') ||
          errorMessage.includes('undefined') ||
          errorMessage.includes('not found')
        ) {
          retryCount++;
          if (retryCount < maxRetries) {
            await this.delay(retryDelayMs);
            continue;
          }
          throw new Error(
            `Failed to initialize dictation: Native module not available after ${maxRetries} retries.`
          );
        }
        
        throw error;
      }
    }
  }

  /**
   * Start listening for speech recognition.
   */
  async startListening(callbacks: {
    onResult: OnResultCallback;
    onStatus: OnStatusCallback;
    onAudioLevel: OnAudioLevelCallback;
    onError?: OnErrorCallback;
    onAudioFile?: OnAudioFileCallback;
    options?: DictationSessionOptions;
  }): Promise<void> {
    const { onResult, onStatus, onAudioLevel, onError, onAudioFile, options } = callbacks;

    // Clear any existing subscriptions
    this.removeAllSubscriptions();

    // Set up event listeners
    this.subscriptions.push(
      DictationEventEmitter.addListener(
        DictationEvents.onResult,
        (event: DictationResult) => {
          onResult(event.text, event.isFinal);
        }
      )
    );

    this.subscriptions.push(
      DictationEventEmitter.addListener(
        DictationEvents.onStatus,
        (event: DictationStatus) => {
          onStatus(event.status);
        }
      )
    );

    this.subscriptions.push(
      DictationEventEmitter.addListener(
        DictationEvents.onAudioLevel,
        (event: DictationAudioLevel) => {
          onAudioLevel(event.level);
        }
      )
    );

    if (onAudioFile) {
      this.subscriptions.push(
        DictationEventEmitter.addListener(
          DictationEvents.onAudioFile,
          (event: DictationAudioFile) => {
            onAudioFile(event);
          }
        )
      );
    }

    this.subscriptions.push(
      DictationEventEmitter.addListener(
        DictationEvents.onError,
        (event: DictationError) => {
          if (onError) {
            onError(event.message, event.code);
          } else {
            console.error('[DictationService] Error:', event.message, event.code);
          }
        }
      )
    );

    // Start native listening
    await NativeDictationModule.startListening(options);
  }

  /**
   * Stop listening and get final result.
   */
  async stopListening(): Promise<void> {
    await NativeDictationModule.stopListening();
  }

  /**
   * Cancel listening without getting a result.
   */
  async cancelListening(): Promise<void> {
    await NativeDictationModule.cancelListening();
  }

  /**
   * Get the current audio level (0.0 - 1.0).
   */
  async getAudioLevel(): Promise<number> {
    return NativeDictationModule.getAudioLevel();
  }

  /**
   * Normalize an existing audio file to canonical format (.m4a).
   */
  async normalizeAudio(sourcePath: string): Promise<NormalizedAudioResult> {
    return NativeDictationModule.normalizeAudio(sourcePath);
  }

  /**
   * Dispose of resources and remove event subscriptions.
   */
  dispose(): void {
    this.removeAllSubscriptions();
    this.isInitialized = false;
  }

  // Private helpers

  private removeAllSubscriptions(): void {
    this.subscriptions.forEach((sub) => sub.remove());
    this.subscriptions = [];
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
```

### 4. React Hooks

**src/hooks/useDictation.ts**
```typescript
import { useState, useRef, useCallback, useEffect } from 'react';
import { DictationService } from '../DictationService';
import type {
  DictationSessionOptions,
  DictationAudioFile,
  DictationStatusValue,
} from '../types';

interface UseDictationOptions {
  onFinalResult?: (text: string) => void;
  onPartialResult?: (text: string) => void;
  onAudioFile?: (file: DictationAudioFile) => void;
  sessionOptions?: DictationSessionOptions;
}

interface UseDictationReturn {
  // State
  isInitialized: boolean;
  isListening: boolean;
  status: DictationStatusValue | null;
  error: string | null;
  partialText: string;
  audioLevel: number;

  // Actions
  initialize: () => Promise<void>;
  startListening: () => Promise<void>;
  stopListening: () => Promise<void>;
  cancelListening: () => Promise<void>;
}

export function useDictation(options?: UseDictationOptions): UseDictationReturn {
  const { onFinalResult, onPartialResult, onAudioFile, sessionOptions } = options ?? {};

  // Refs
  const serviceRef = useRef<DictationService | null>(null);

  // State
  const [isInitialized, setIsInitialized] = useState(false);
  const [isListening, setIsListening] = useState(false);
  const [status, setStatus] = useState<DictationStatusValue | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [partialText, setPartialText] = useState('');
  const [audioLevel, setAudioLevel] = useState(0);

  // Initialize service on mount
  useEffect(() => {
    serviceRef.current = new DictationService();

    return () => {
      serviceRef.current?.dispose();
      serviceRef.current = null;
    };
  }, []);

  // Initialize
  const initialize = useCallback(async () => {
    if (!serviceRef.current) return;

    try {
      setError(null);
      await serviceRef.current.initialize();
      setIsInitialized(true);
      setStatus('ready');
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      throw err;
    }
  }, []);

  // Start listening
  const startListening = useCallback(async () => {
    if (!serviceRef.current || !isInitialized) {
      throw new Error('Dictation service not initialized');
    }

    try {
      setError(null);
      setPartialText('');
      setAudioLevel(0);

      await serviceRef.current.startListening({
        onResult: (text, isFinal) => {
          if (isFinal) {
            onFinalResult?.(text);
            setPartialText('');
          } else {
            setPartialText(text);
            onPartialResult?.(text);
          }
        },
        onStatus: (newStatus) => {
          setStatus(newStatus);
          setIsListening(newStatus === 'listening');
        },
        onAudioLevel: (level) => {
          setAudioLevel(level);
        },
        onError: (message, code) => {
          setError(`${message}${code ? ` (${code})` : ''}`);
          setIsListening(false);
        },
        onAudioFile: onAudioFile,
        options: sessionOptions,
      });

      setIsListening(true);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      setIsListening(false);
      throw err;
    }
  }, [isInitialized, onFinalResult, onPartialResult, onAudioFile, sessionOptions]);

  // Stop listening
  const stopListening = useCallback(async () => {
    if (!serviceRef.current) return;

    try {
      await serviceRef.current.stopListening();
      setIsListening(false);
      setAudioLevel(0);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
    }
  }, []);

  // Cancel listening
  const cancelListening = useCallback(async () => {
    if (!serviceRef.current) return;

    try {
      await serviceRef.current.cancelListening();
      setIsListening(false);
      setPartialText('');
      setAudioLevel(0);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
    }
  }, []);

  return {
    isInitialized,
    isListening,
    status,
    error,
    partialText,
    audioLevel,
    initialize,
    startListening,
    stopListening,
    cancelListening,
  };
}
```

**src/hooks/useWaveform.ts**
```typescript
import { useState, useRef, useCallback } from 'react';

const DEFAULT_BUFFER_SIZE = 100;

interface UseWaveformOptions {
  bufferSize?: number;
}

interface UseWaveformReturn {
  levels: number[];
  currentLevel: number;
  updateLevel: (level: number) => void;
  reset: () => void;
}

/**
 * Hook for managing waveform visualization data.
 * Maintains a fixed-size, pre-filled buffer for ChatGPT-style waveform.
 */
export function useWaveform(options?: UseWaveformOptions): UseWaveformReturn {
  const { bufferSize = DEFAULT_BUFFER_SIZE } = options ?? {};

  // Initialize with zeros
  const [levels, setLevels] = useState<number[]>(() => 
    Array(bufferSize).fill(0)
  );
  const [currentLevel, setCurrentLevel] = useState(0);
  
  const levelsRef = useRef<number[]>(levels);

  const updateLevel = useCallback((level: number) => {
    const clampedLevel = Math.max(0, Math.min(1, level));
    setCurrentLevel(clampedLevel);

    // Update buffer: remove first, add new
    const newLevels = [...levelsRef.current.slice(1), clampedLevel];
    levelsRef.current = newLevels;
    setLevels(newLevels);
  }, []);

  const reset = useCallback(() => {
    const emptyLevels = Array(bufferSize).fill(0);
    levelsRef.current = emptyLevels;
    setLevels(emptyLevels);
    setCurrentLevel(0);
  }, [bufferSize]);

  return {
    levels,
    currentLevel,
    updateLevel,
    reset,
  };
}
```

### 5. Main Exports

**src/index.ts**
```typescript
// Service
export { DictationService } from './DictationService';

// Types
export type {
  DictationSessionOptions,
  DictationResult,
  DictationStatus,
  DictationStatusValue,
  DictationAudioLevel,
  DictationAudioFile,
  DictationError,
  NormalizedAudioResult,
  OnResultCallback,
  OnStatusCallback,
  OnAudioLevelCallback,
  OnAudioFileCallback,
  OnErrorCallback,
} from './types';

// Hooks
export { useDictation } from './hooks/useDictation';
export { useWaveform } from './hooks/useWaveform';

// Components (implemented in Phase 7)
export { Waveform } from './components/Waveform';
export { AudioControlsDecorator } from './components/AudioControlsDecorator';
```

## JavaScript to Native Interop Matrix

The following table shows how JavaScript options map to native behavior:

| JavaScript Option | Native Behavior | Notes |
|------------------|-----------------|-------|
| `initialize({ locale })` | `SpeechRecognizerManager.initialize(locale:)` | BCP-47 format (e.g., "en-US"). Defaults to system locale if omitted. |
| `startListening({ preserveAudio })` | `DictationStartOptions.preserveAudio` | Enables audio file preservation during recording. |
| `startListening({ preservedAudioFilePath })` | `DictationStartOptions.preservedAudioFilePath` | Custom file path (relative to Documents or absolute). |
| `startListening({ deleteAudioIfCancelled })` | `DictationStartOptions.deleteAudioIfCancelled` | Controls whether audio file is deleted on cancellation. Default: `true`. |
| `initialize({ maxRetries, retryDelayMs })` | Retry logic in TypeScript | Only affects TypeScript initialization retry, not native module. |

**Locale Handling:**
- Locale is passed from TypeScript `initialize()` → Native `DictationModule.initialize()` → `DictationCoordinator.initialize()` → `SpeechRecognizerManager.initialize()`
- If locale is omitted, `Locale.current` is used (system default)
- Locale affects speech recognition language and on-device availability

**Audio Preservation:**
- All `DictationSessionOptions` fields are forwarded exactly as typed to the native module
- The Swift `DictationStartOptions` struct receives all fields via dictionary parsing
- Audio preservation path overrides and cancellation semantics are handled in `DictationCoordinator`

## Usage Example

```tsx
import React, { useEffect, useState } from 'react';
import { View, Text, TextInput, Pressable } from 'react-native';
import { useDictation, useWaveform, Waveform } from 'react-native-dictation';

function DictationScreen() {
  const [inputText, setInputText] = useState('');
  
  const waveform = useWaveform();
  
  const dictation = useDictation({
    onFinalResult: (text) => {
      setInputText((prev) => `${prev}${text} `);
    },
    sessionOptions: {
      preserveAudio: true,
      deleteAudioIfCancelled: false,
    },
  });

  // Initialize on mount with locale
  useEffect(() => {
    dictation.initialize({ locale: 'en-US' }).catch(console.error);
  }, []);

  // Forward audio levels to waveform
  useEffect(() => {
    if (dictation.isListening) {
      waveform.updateLevel(dictation.audioLevel);
    }
  }, [dictation.audioLevel, dictation.isListening]);

  // Reset waveform when not listening
  useEffect(() => {
    if (!dictation.isListening) {
      waveform.reset();
    }
  }, [dictation.isListening]);

  const handleToggleMic = async () => {
    if (dictation.isListening) {
      await dictation.stopListening();
    } else {
      await dictation.startListening();
    }
  };

  return (
    <View style={{ flex: 1, padding: 16 }}>
      <TextInput
        value={inputText}
        onChangeText={setInputText}
        placeholder="Tap mic to start dictating..."
        multiline
        style={{ height: 200, borderWidth: 1, padding: 8 }}
      />

      {dictation.isListening && (
        <Waveform
          levels={waveform.levels}
          height={40}
          barColor="#007AFF"
        />
      )}

      <Pressable onPress={handleToggleMic} disabled={!dictation.isInitialized}>
        <Text>{dictation.isListening ? '⏹ Stop' : '🎤 Start'}</Text>
      </Pressable>

      {dictation.error && (
        <Text style={{ color: 'red' }}>{dictation.error}</Text>
      )}
    </View>
  );
}
```

## Verification Checklist

- [ ] TypeScript types compile without errors
- [ ] `DictationService` connects to native module
- [ ] Events are received and parsed correctly
- [ ] `useDictation` hook manages state properly
- [ ] `useWaveform` maintains sliding window buffer
- [ ] Initialization retry logic works

## Next Steps

Proceed to [07_WAVEFORM_COMPONENTS.md](./07_WAVEFORM_COMPONENTS.md) to implement the React Native waveform visualization components.
