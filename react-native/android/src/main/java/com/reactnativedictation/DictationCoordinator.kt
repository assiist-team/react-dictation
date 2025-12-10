package com.reactnativedictation

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.*

class DictationCoordinator(
    private val context: Context,
    private val eventEmitter: DictationModule
) {
    private var speechRecognizer: SpeechRecognizer? = null
    private var audioEngineManager: AudioEngineManager? = null
    private var isListening = false
    private var currentOptions: DictationOptions = DictationOptions()
    
    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioLevelRunnable: Runnable? = null

    fun initialize() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            throw Exception("Speech recognition not available on this device")
        }

        mainHandler.post {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context).apply {
                setRecognitionListener(createRecognitionListener())
            }
        }

        audioEngineManager = AudioEngineManager(context)
        
        eventEmitter.emitStatus("ready")
    }

    fun startListening(options: DictationOptions) {
        if (isListening) return

        currentOptions = options
        isListening = true

        // Start audio engine for waveform visualization
        val preservationPath = if (options.preserveAudio) {
            options.preservedAudioFilePath ?: CanonicalAudioStorage.makeRecordingPath(context)
        } else null

        audioEngineManager?.startRecording(preservationPath)

        // Start speech recognition
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }

        mainHandler.post {
            speechRecognizer?.startListening(intent)
        }

        // Start audio level streaming
        startAudioLevelStreaming()

        eventEmitter.emitStatus("listening")
    }

    fun stopListening() {
        if (!isListening) return

        isListening = false
        stopAudioLevelStreaming()

        mainHandler.post {
            speechRecognizer?.stopListening()
        }

        val result = audioEngineManager?.stopRecording(deleteFile = false)

        eventEmitter.emitStatus("stopped")

        // Emit audio file if preserved
        result?.let { audioResult ->
            eventEmitter.emitAudioFile(
                path = audioResult.filePath,
                durationMs = audioResult.durationMs,
                fileSizeBytes = audioResult.fileSizeBytes,
                sampleRate = audioResult.sampleRate,
                channelCount = audioResult.channelCount,
                wasCancelled = false
            )
        }
    }

    fun cancelListening() {
        if (!isListening) return

        isListening = false
        stopAudioLevelStreaming()

        mainHandler.post {
            speechRecognizer?.cancel()
        }

        val deleteFile = currentOptions.deleteAudioIfCancelled
        val result = audioEngineManager?.stopRecording(deleteFile = deleteFile)

        eventEmitter.emitStatus("cancelled")

        // Emit audio file if preserved and not deleted
        if (!deleteFile) {
            result?.let { audioResult ->
                eventEmitter.emitAudioFile(
                    path = audioResult.filePath,
                    durationMs = audioResult.durationMs,
                    fileSizeBytes = audioResult.fileSizeBytes,
                    sampleRate = audioResult.sampleRate,
                    channelCount = audioResult.channelCount,
                    wasCancelled = true
                )
            }
        }
    }

    fun getAudioLevel(): Float {
        return audioEngineManager?.getAudioLevel() ?: 0f
    }

    private fun createRecognitionListener(): RecognitionListener {
        return object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {
                // Alternative audio level source (less smooth than AudioRecord)
            }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}

            override fun onError(error: Int) {
                val errorMessage = when (error) {
                    SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
                    SpeechRecognizer.ERROR_CLIENT -> "Client error"
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
                    SpeechRecognizer.ERROR_NETWORK -> "Network error"
                    SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
                    SpeechRecognizer.ERROR_NO_MATCH -> "No speech match"
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognizer busy"
                    SpeechRecognizer.ERROR_SERVER -> "Server error"
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Speech timeout"
                    else -> "Unknown error"
                }
                
                eventEmitter.emitError(errorMessage, "RECOGNITION_ERROR")
                
                if (error != SpeechRecognizer.ERROR_NO_MATCH) {
                    isListening = false
                    stopAudioLevelStreaming()
                    audioEngineManager?.stopRecording(deleteFile = true)
                }
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                matches?.firstOrNull()?.let { text ->
                    eventEmitter.emitResult(text, true)
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                matches?.firstOrNull()?.let { text ->
                    eventEmitter.emitResult(text, false)
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        }
    }

    private fun startAudioLevelStreaming() {
        stopAudioLevelStreaming()
        
        audioLevelRunnable = object : Runnable {
            override fun run() {
                if (isListening) {
                    val level = audioEngineManager?.getAudioLevel() ?: 0f
                    eventEmitter.emitAudioLevel(level)
                    mainHandler.postDelayed(this, 33) // ~30 FPS
                }
            }
        }
        mainHandler.post(audioLevelRunnable!!)
    }

    private fun stopAudioLevelStreaming() {
        audioLevelRunnable?.let { mainHandler.removeCallbacks(it) }
        audioLevelRunnable = null
    }

    fun destroy() {
        isListening = false
        stopAudioLevelStreaming()
        
        mainHandler.post {
            speechRecognizer?.destroy()
            speechRecognizer = null
        }
        
        audioEngineManager?.release()
        audioEngineManager = null
    }
}
