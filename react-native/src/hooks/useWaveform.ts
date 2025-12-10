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
  const initialLevels = Array(bufferSize).fill(0);
  const [levels, setLevels] = useState<number[]>(initialLevels);
  const [currentLevel, setCurrentLevel] = useState(0);
  
  const levelsRef = useRef<number[]>(initialLevels);

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
