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
