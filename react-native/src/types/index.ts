export interface DictationSessionOptions {
  preserveAudio?: boolean;
  preservedAudioFilePath?: string;
  deleteAudioIfCancelled?: boolean;
}

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

export interface DictationAudioLevel {
  level: number;
}

export interface DictationAudioFile {
  path: string;
  durationMs: number;
  fileSizeBytes: number;
  sampleRate: number;
  channelCount: number;
  wasCancelled: boolean;
}

export interface DictationError {
  message: string;
  code?: string;
}

export interface NormalizedAudioResult {
  canonicalPath: string;
  durationMs: number;
  sizeBytes: number;
  wasReencoded: boolean;
}

export interface DictationModuleInterface {
  initialize(options?: { locale?: string }): Promise<void>;
  startListening(options?: DictationSessionOptions): Promise<void>;
  stopListening(): Promise<void>;
  cancelListening(): Promise<void>;
  getAudioLevel(): Promise<number>;
  normalizeAudio(sourcePath: string): Promise<NormalizedAudioResult>;
}

// Callback types
export type OnResultCallback = (text: string, isFinal: boolean) => void;
export type OnStatusCallback = (status: DictationStatusValue) => void;
export type OnAudioLevelCallback = (level: number) => void;
export type OnAudioFileCallback = (file: DictationAudioFile) => void;
export type OnErrorCallback = (message: string, code?: string) => void;
