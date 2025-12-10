import { useState, useRef, useCallback, useEffect } from 'react';
import { DictationService } from '../DictationService';
import type {
  DictationSessionOptions,
  DictationAudioFile,
  DictationStatusValue,
} from '../types';

interface UseDictationOptions {
  locale?: string;
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
  const { locale, onFinalResult, onPartialResult, onAudioFile, sessionOptions } = options ?? {};

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
      await serviceRef.current.initialize(locale ? { locale } : undefined);
      setIsInitialized(true);
      setStatus('ready');
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      throw err;
    }
  }, [locale]);

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
