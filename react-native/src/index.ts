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

// Components
export { Waveform, AudioControlsDecorator } from './components';
