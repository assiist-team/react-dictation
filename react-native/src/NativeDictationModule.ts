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
