import { renderHook, act } from '@testing-library/react-native';
import { useWaveform } from '../../src/hooks/useWaveform';

describe('useWaveform', () => {
  it('should initialize with zeros', () => {
    const { result } = renderHook(() => useWaveform());

    expect(result.current.levels).toHaveLength(100);
    expect(result.current.levels.every(l => l === 0)).toBe(true);
    expect(result.current.currentLevel).toBe(0);
  });

  it('should initialize with custom buffer size', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 50 }));

    expect(result.current.levels).toHaveLength(50);
    expect(result.current.levels.every(l => l === 0)).toBe(true);
  });

  it('should update level and shift buffer', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 5 }));

    act(() => {
      result.current.updateLevel(0.5);
    });

    expect(result.current.currentLevel).toBe(0.5);
    expect(result.current.levels).toEqual([0, 0, 0, 0, 0.5]);
  });

  it('should shift buffer correctly on multiple updates', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 5 }));

    act(() => {
      result.current.updateLevel(0.3);
      result.current.updateLevel(0.6);
      result.current.updateLevel(0.9);
    });

    expect(result.current.currentLevel).toBe(0.9);
    expect(result.current.levels).toEqual([0, 0, 0.3, 0.6, 0.9]);
  });

  it('should clamp levels to 0-1', () => {
    const { result } = renderHook(() => useWaveform());

    act(() => {
      result.current.updateLevel(1.5);
    });
    expect(result.current.currentLevel).toBe(1);
    expect(result.current.levels[result.current.levels.length - 1]).toBe(1);

    act(() => {
      result.current.updateLevel(-0.5);
    });
    expect(result.current.currentLevel).toBe(0);
    expect(result.current.levels[result.current.levels.length - 1]).toBe(0);
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

  it('should maintain buffer size after reset', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 10 }));

    act(() => {
      result.current.updateLevel(0.5);
      result.current.reset();
    });

    expect(result.current.levels).toHaveLength(10);
  });

  it('should handle rapid updates', () => {
    const { result } = renderHook(() => useWaveform({ bufferSize: 3 }));

    act(() => {
      for (let i = 0; i < 10; i++) {
        result.current.updateLevel(i / 10);
      }
    });

    // Should only keep last 3 values
    expect(result.current.levels).toHaveLength(3);
    expect(result.current.currentLevel).toBe(0.9);
  });
});
