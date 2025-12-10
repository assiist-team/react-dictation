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

  // Calculate bar dimensions based on actual container width
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
