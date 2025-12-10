# Phase 7: Waveform Components

## Overview

This phase implements React Native UI components for waveform visualization and audio controls, replacing Flutter's `NativeWaveform`, `WaveformPainter`, and `AudioControlsDecorator` widgets.

## Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ AudioControlsDecorator                                          │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │ children (e.g., TextInput)                               │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │ Control Row (when listening)                             │  │
│   │  ┌─────────┐   ┌────────────────┐   ┌────────┐  ┌─────┐  │  │
│   │  │ Cancel  │   │   Waveform     │   │ Timer  │  │ ✓   │  │  │
│   │  │   ✕     │   │  ▁▃▅▇▅▃▁▃▅   │   │ 01:23  │  │     │  │  │
│   │  └─────────┘   └────────────────┘   └────────┘  └─────┘  │  │
│   └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│   ┌──────────────────────────────────────────────────────────┐  │
│   │ Mic Button (when idle)                                   │  │
│   │                    ┌─────┐                               │  │
│   │                    │ 🎤  │                               │  │
│   │                    └─────┘                               │  │
│   └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation

### 1. Waveform Component (SVG-based)

**src/components/Waveform.tsx**
```tsx
import React, { useMemo, useState } from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import Svg, { Rect } from 'react-native-svg';

interface WaveformProps {
  /** Array of audio levels (0.0 - 1.0) */
  levels: number[];
  /** Height of the waveform in pixels */
  height?: number;
  /** Width of the waveform (default: full width) */
  width?: number | '100%';
  /** Color of the bars */
  barColor?: string;
  /** Number of visible bars (default: 50) */
  visibleBars?: number;
  /** Spacing between bars in pixels */
  barSpacing?: number;
  /** Container style */
  style?: ViewStyle;
}

/**
 * Waveform visualization component using SVG.
 * Displays audio levels as vertical bars, similar to ChatGPT's voice interface.
 * 
 * The component is responsive and automatically adjusts bar widths based on the
 * container size. When width="100%", it measures the container using onLayout
 * and updates when the parent resizes.
 */
export function Waveform({
  levels,
  height = 40,
  width = '100%',
  barColor = '#8E8E93',
  visibleBars = 50,
  barSpacing = 2,
  style,
}: WaveformProps) {
  // Measure container width for responsive layout
  const [containerWidth, setContainerWidth] = useState<number>(
    typeof width === 'number' ? width : 300
  );

  // Calculate bar dimensions
  const bars = useMemo(() => {
    // Take the most recent `visibleBars` samples
    const startIndex = Math.max(0, levels.length - visibleBars);
    const visibleLevels = levels.slice(startIndex);

    // Shape the levels for better visualization
    return visibleLevels.map((level) => {
      const clampedLevel = Math.max(0, Math.min(1, level));
      // Apply amplitude shaping (same as Flutter)
      const shapedLevel = Math.pow(clampedLevel, 1.25);
      // Blend with original for quiet speech visibility
      const blendedLevel = shapedLevel * 0.85 + clampedLevel * 0.15;
      return blendedLevel;
    });
  }, [levels, visibleBars]);

  // Memoize bar dimensions to avoid layout thrash
  const barDimensions = useMemo(() => {
    const actualWidth = typeof width === 'number' ? width : containerWidth;
    const totalSpacing = barSpacing * (visibleBars - 1);
    const availableWidth = actualWidth - totalSpacing;
    const barWidth = availableWidth / visibleBars;
    
    return {
      barWidth,
      totalSpacing,
      actualWidth,
    };
  }, [width, containerWidth, visibleBars, barSpacing]);

  // Render using SVG for smooth performance
  return (
    <View
      style={[styles.container, { height }, style]}
      onLayout={(e) => {
        // Update container width when layout changes (for responsive behavior)
        if (width === '100%') {
          setContainerWidth(e.nativeEvent.layout.width);
        }
      }}
    >
      <Svg width={barDimensions.actualWidth} height={height}>
        {bars.map((level, index) => {
          // Min height for visibility, max 90% of container
          const minBarHeight = 2;
          const maxBarHeight = height * 0.9;
          const barHeight = Math.max(minBarHeight, level * maxBarHeight);

          const x = index * (barDimensions.barWidth + barSpacing);
          const y = (height - barHeight) / 2;

          return (
            <Rect
              key={index}
              x={x}
              y={y}
              width={barDimensions.barWidth}
              height={barHeight}
              rx={barDimensions.barWidth / 2} // Rounded corners
              fill={barColor}
            />
          );
        })}
      </Svg>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    overflow: 'hidden',
  },
});
```

### 2. Alternative: Canvas-based Waveform (for Expo)

**src/components/WaveformCanvas.tsx**
```tsx
import React, { useMemo } from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import { Canvas, RoundedRect } from '@shopify/react-native-skia';

interface WaveformCanvasProps {
  levels: number[];
  height?: number;
  barColor?: string;
  visibleBars?: number;
  barSpacing?: number;
  style?: ViewStyle;
}

/**
 * Waveform using Skia Canvas for high performance.
 * Alternative to SVG for smoother 60fps animations.
 * 
 * The component is responsive and automatically adjusts bar widths based on the
 * container size using onLayout measurement.
 */
export function WaveformCanvas({
  levels,
  height = 40,
  barColor = '#8E8E93',
  visibleBars = 50,
  barSpacing = 2,
  style,
}: WaveformCanvasProps) {
  const [containerWidth, setContainerWidth] = React.useState(300);

  // Calculate bar dimensions with memoization
  const barDimensions = useMemo(() => {
    const totalSpacing = barSpacing * (visibleBars - 1);
    const availableWidth = containerWidth - totalSpacing;
    const barWidth = availableWidth / visibleBars;
    return { barWidth, totalSpacing };
  }, [containerWidth, visibleBars, barSpacing]);

  // Process levels with memoization
  const processedLevels = useMemo(() => {
    const startIndex = Math.max(0, levels.length - visibleBars);
    return levels.slice(startIndex).map((level) => {
      const clampedLevel = Math.max(0, Math.min(1, level));
      const shapedLevel = Math.pow(clampedLevel, 1.25);
      return shapedLevel * 0.85 + clampedLevel * 0.15;
    });
  }, [levels, visibleBars]);

  return (
    <View 
      style={[styles.container, { height }, style]}
      onLayout={(e) => setContainerWidth(e.nativeEvent.layout.width)}
    >
      <Canvas style={{ flex: 1 }}>
        {processedLevels.map((blendedLevel, index) => {
          const minBarHeight = 2;
          const maxBarHeight = height * 0.9;
          const barHeight = Math.max(minBarHeight, blendedLevel * maxBarHeight);

          const x = index * (barDimensions.barWidth + barSpacing);
          const y = (height - barHeight) / 2;

          return (
            <RoundedRect
              key={index}
              x={x}
              y={y}
              width={barDimensions.barWidth}
              height={barHeight}
              r={barDimensions.barWidth / 2}
              color={barColor}
            />
          );
        })}
      </Canvas>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    overflow: 'hidden',
  },
});
```

### 3. Audio Controls Decorator

**src/components/AudioControlsDecorator.tsx**
```tsx
import React from 'react';
import { View, Text, Pressable, StyleSheet, ActivityIndicator, ViewStyle } from 'react-native';
import { Waveform } from './Waveform';

interface AudioControlsDecoratorProps {
  /** The child component (typically a TextInput) */
  children: React.ReactNode;
  /** Whether dictation is active */
  isListening: boolean;
  /** Whether processing (showing spinner instead of checkmark) */
  isProcessing?: boolean;
  /** Elapsed recording time */
  elapsedTime: number; // in seconds
  /** Audio levels for waveform */
  waveformLevels?: number[];
  /** Called when mic/checkmark button is pressed */
  onMicPressed?: () => void;
  /** Called when cancel button is pressed */
  onCancelPressed?: () => void;
  /** Primary color for buttons */
  primaryColor?: string;
  /** Text/icon color */
  iconColor?: string;
  /** Container style */
  style?: ViewStyle;
}

/**
 * Decorator component that adds audio recording controls below a child widget.
 * Mimics the Flutter AudioControlsDecorator behavior.
 */
export function AudioControlsDecorator({
  children,
  isListening,
  isProcessing = false,
  elapsedTime,
  waveformLevels = [],
  onMicPressed,
  onCancelPressed,
  primaryColor = '#007AFF',
  iconColor = '#8E8E93',
  style,
}: AudioControlsDecoratorProps) {
  // Format time as M:SS
  const formatTime = (seconds: number): string => {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  };

  return (
    <View style={[styles.container, style]}>
      {/* Child component (e.g., TextInput) */}
      {children}

      <View style={styles.controlsContainer}>
        {!isListening ? (
          // Idle state: show mic button
          onMicPressed && (
            <Pressable
              onPress={onMicPressed}
              style={[styles.micButton, { backgroundColor: primaryColor }]}
            >
              <Text style={styles.micIcon}>🎤</Text>
            </Pressable>
          )
        ) : (
          // Listening state: show full control row
          <View style={styles.controlRow}>
            {/* Cancel button */}
            {onCancelPressed && (
              <Pressable onPress={onCancelPressed} style={styles.iconButton}>
                <Text style={[styles.icon, { color: iconColor }]}>✕</Text>
              </Pressable>
            )}

            {/* Waveform */}
            <View style={styles.waveformContainer}>
              <Waveform
                levels={waveformLevels}
                height={30}
                barColor={iconColor}
              />
            </View>

            {/* Timer */}
            <Text style={[styles.timer, { color: iconColor }]}>
              {formatTime(elapsedTime)}
            </Text>

            {/* Checkmark or spinner */}
            {isProcessing ? (
              <ActivityIndicator size="small" color={iconColor} style={styles.iconButton} />
            ) : (
              <Pressable onPress={onMicPressed} style={styles.iconButton}>
                <Text style={[styles.icon, { color: iconColor }]}>✓</Text>
              </Pressable>
            )}
          </View>
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    width: '100%',
  },
  controlsContainer: {
    marginTop: 8,
    alignItems: 'center',
  },
  micButton: {
    width: 60,
    height: 60,
    borderRadius: 30,
    justifyContent: 'center',
    alignItems: 'center',
    marginTop: 8,
  },
  micIcon: {
    fontSize: 28,
  },
  controlRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 4,
    paddingHorizontal: 8,
    width: '100%',
  },
  iconButton: {
    padding: 8,
    minWidth: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  icon: {
    fontSize: 20,
    fontWeight: '600',
  },
  waveformContainer: {
    flex: 1,
    marginHorizontal: 8,
  },
  timer: {
    fontSize: 13,
    marginRight: 8,
    fontVariant: ['tabular-nums'],
  },
});
```

### 4. Component Exports

**src/components/index.ts**
```typescript
export { Waveform } from './Waveform';
export { AudioControlsDecorator } from './AudioControlsDecorator';

// Optional Skia canvas version
// export { WaveformCanvas } from './WaveformCanvas';
```

## Complete Usage Example

```tsx
import React, { useState, useEffect, useRef } from 'react';
import { View, TextInput, StyleSheet, SafeAreaView } from 'react-native';
import {
  useDictation,
  useWaveform,
  AudioControlsDecorator,
} from 'react-native-dictation';

export function DictationField() {
  const [text, setText] = useState('');
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const timerRef = useRef<NodeJS.Timeout | null>(null);

  const waveform = useWaveform();

  const dictation = useDictation({
    onFinalResult: (finalText) => {
      setText((prev) => `${prev}${finalText} `);
    },
    sessionOptions: {
      preserveAudio: true,
    },
  });

  // Initialize on mount
  useEffect(() => {
    dictation.initialize();
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, []);

  // Sync audio levels to waveform
  useEffect(() => {
    if (dictation.isListening) {
      waveform.updateLevel(dictation.audioLevel);
    }
  }, [dictation.audioLevel]);

  // Timer management
  useEffect(() => {
    if (dictation.isListening) {
      setElapsedSeconds(0);
      timerRef.current = setInterval(() => {
        setElapsedSeconds((prev) => prev + 1);
      }, 1000);
    } else {
      if (timerRef.current) {
        clearInterval(timerRef.current);
        timerRef.current = null;
      }
      waveform.reset();
    }

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [dictation.isListening]);

  const handleMicPress = async () => {
    if (dictation.isListening) {
      await dictation.stopListening();
    } else {
      await dictation.startListening();
    }
  };

  const handleCancelPress = async () => {
    await dictation.cancelListening();
    setElapsedSeconds(0);
  };

  return (
    <SafeAreaView style={styles.container}>
      <AudioControlsDecorator
        isListening={dictation.isListening}
        elapsedTime={elapsedSeconds}
        waveformLevels={waveform.levels}
        onMicPressed={handleMicPress}
        onCancelPressed={handleCancelPress}
      >
        <TextInput
          style={styles.textInput}
          value={text}
          onChangeText={setText}
          placeholder="Tap the mic to start dictating..."
          multiline
          textAlignVertical="top"
        />
      </AudioControlsDecorator>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 16,
    backgroundColor: '#fff',
  },
  textInput: {
    borderWidth: 1,
    borderColor: '#E5E5E5',
    borderRadius: 8,
    padding: 12,
    minHeight: 150,
    fontSize: 16,
  },
});
```

## Performance Considerations

### SVG vs Canvas

| Approach | Pros | Cons |
|----------|------|------|
| SVG (`react-native-svg`) | Simple, widely supported | May lag at 60fps |
| Skia Canvas | 60fps, smooth | Larger bundle, more setup |
| Custom Native View | Best performance | Complex maintenance |

**Recommendation:** Start with SVG. If performance is insufficient at 30fps updates, switch to Skia.

### Optimizations

1. **Memoization**: Use `useMemo` for bar calculations
2. **Throttling**: Native already sends at 30fps, no JS throttling needed
3. **Reduced redraws**: Only update when `levels` actually change

## Dependencies

Add to `package.json`:

```json
{
  "dependencies": {
    "react-native-svg": "^14.0.0"
  }
}
```

For Skia (optional):
```json
{
  "dependencies": {
    "@shopify/react-native-skia": "^0.1.0"
  }
}
```

## Verification Checklist

- [ ] `Waveform` renders SVG bars correctly
- [ ] Bar heights respond to audio level changes
- [ ] `AudioControlsDecorator` shows/hides controls based on state
- [ ] Timer increments while listening
- [ ] Cancel and checkmark buttons trigger callbacks
- [ ] Components integrate smoothly with hooks

## Next Steps

Proceed to [08_ANDROID_IMPLEMENTATION.md](./08_ANDROID_IMPLEMENTATION.md) to implement the Android native module.
