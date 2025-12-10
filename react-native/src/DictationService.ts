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
