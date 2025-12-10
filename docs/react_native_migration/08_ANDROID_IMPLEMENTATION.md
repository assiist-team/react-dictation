# Phase 8: Android Implementation

## Overview

This phase implements the Android native module using Kotlin. Android's speech recognition differs significantly from iOS, using `SpeechRecognizer` (which requires Google Play Services) or Android's built-in speech recognition.

## Architecture Differences

| Aspect | iOS | Android |
|--------|-----|---------|
| Speech Engine | `SFSpeechRecognizer` | `SpeechRecognizer` (Google) |
| Audio Engine | `AVAudioEngine` | `AudioRecord` |
| Encoding | `AVAssetWriter` (AAC) | `MediaCodec` (AAC) |
| Offline Support | Apple on-device models | Limited (varies by device) |

## Implementation

### 1. Module Package

**android/src/main/java/com/reactnativedictation/DictationPackage.kt**
```kotlin
package com.reactnativedictation

import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ViewManager

class DictationPackage : ReactPackage {
    override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> {
        return listOf(DictationModule(reactContext))
    }

    override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> {
        return emptyList()
    }
}
```

### 2. Native Module

**android/src/main/java/com/reactnativedictation/DictationModule.kt**
```kotlin
package com.reactnativedictation

import android.Manifest
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener

class DictationModule(reactContext: ReactApplicationContext) : 
    ReactContextBaseJavaModule(reactContext),
    PermissionListener {

    private var coordinator: DictationCoordinator? = null
    private var permissionPromise: Promise? = null
    private var pendingOptions: DictationOptions? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun getName(): String = "DictationModule"

    // Events that can be sent to JavaScript
    companion object {
        const val EVENT_ON_RESULT = "onResult"
        const val EVENT_ON_STATUS = "onStatus"
        const val EVENT_ON_AUDIO_LEVEL = "onAudioLevel"
        const val EVENT_ON_AUDIO_FILE = "onAudioFile"
        const val EVENT_ON_ERROR = "onError"

        const val PERMISSION_REQUEST_CODE = 1001
    }

    // MARK: - Bridge Methods

    @ReactMethod
    fun initialize(promise: Promise) {
        mainHandler.post {
            try {
                if (coordinator == null) {
                    coordinator = DictationCoordinator(
                        context = reactApplicationContext,
                        eventEmitter = this
                    )
                }
                coordinator?.initialize()
                promise.resolve(null)
            } catch (e: Exception) {
                promise.reject("INIT_ERROR", e.message, e)
            }
        }
    }

    @ReactMethod
    fun startListening(options: ReadableMap?, promise: Promise) {
        mainHandler.post {
            val coordinator = this.coordinator
            if (coordinator == null) {
                promise.reject("NOT_INITIALIZED", "Dictation service not initialized")
                return@post
            }

            // Parse options first (before permission check)
            val opts = parseOptions(options)

            // Check permission
            if (!hasRecordPermission()) {
                // Store the promise and options for use after permission grant
                permissionPromise = promise
                pendingOptions = opts
                requestRecordPermission()
                return@post
            }

            try {
                coordinator.startListening(opts)
                promise.resolve(null)
            } catch (e: Exception) {
                promise.reject("START_ERROR", e.message, e)
            }
        }
    }

    @ReactMethod
    fun stopListening(promise: Promise) {
        mainHandler.post {
            try {
                coordinator?.stopListening()
                promise.resolve(null)
            } catch (e: Exception) {
                promise.reject("STOP_ERROR", e.message, e)
            }
        }
    }

    @ReactMethod
    fun cancelListening(promise: Promise) {
        mainHandler.post {
            try {
                coordinator?.cancelListening()
                promise.resolve(null)
            } catch (e: Exception) {
                promise.reject("CANCEL_ERROR", e.message, e)
            }
        }
    }

    @ReactMethod
    fun getAudioLevel(promise: Promise) {
        try {
            val level = coordinator?.getAudioLevel() ?: 0.0f
            promise.resolve(level.toDouble())
        } catch (e: Exception) {
            promise.resolve(0.0)
        }
    }

    @ReactMethod
    fun normalizeAudio(sourcePath: String, promise: Promise) {
        Thread {
            try {
                val encoder = AudioEncoderManager(reactApplicationContext)
                val result = encoder.normalizeAudio(sourcePath)
                
                val response = Arguments.createMap().apply {
                    putString("canonicalPath", result.canonicalPath)
                    putDouble("durationMs", result.durationMs)
                    putDouble("sizeBytes", result.sizeBytes.toDouble())
                    putBoolean("wasReencoded", result.wasReencoded)
                }
                
                mainHandler.post { promise.resolve(response) }
            } catch (e: Exception) {
                mainHandler.post { promise.reject("NORMALIZE_ERROR", e.message, e) }
            }
        }.start()
    }

    // Required for NativeEventEmitter
    @ReactMethod
    fun addListener(eventName: String) {
        // Keep: Required for RN NativeEventEmitter
    }

    @ReactMethod
    fun removeListeners(count: Int) {
        // Keep: Required for RN NativeEventEmitter
    }

    // MARK: - Event Emission

    fun emitResult(text: String, isFinal: Boolean) {
        val params = Arguments.createMap().apply {
            putString("text", text)
            putBoolean("isFinal", isFinal)
        }
        sendEvent(EVENT_ON_RESULT, params)
    }

    fun emitStatus(status: String) {
        val params = Arguments.createMap().apply {
            putString("status", status)
        }
        sendEvent(EVENT_ON_STATUS, params)
    }

    fun emitAudioLevel(level: Float) {
        val params = Arguments.createMap().apply {
            putDouble("level", level.toDouble())
        }
        sendEvent(EVENT_ON_AUDIO_LEVEL, params)
    }

    fun emitAudioFile(
        path: String,
        durationMs: Double,
        fileSizeBytes: Long,
        sampleRate: Double,
        channelCount: Int,
        wasCancelled: Boolean
    ) {
        val params = Arguments.createMap().apply {
            putString("path", path)
            putDouble("durationMs", durationMs)
            putDouble("fileSizeBytes", fileSizeBytes.toDouble())
            putDouble("sampleRate", sampleRate)
            putInt("channelCount", channelCount)
            putBoolean("wasCancelled", wasCancelled)
        }
        sendEvent(EVENT_ON_AUDIO_FILE, params)
    }

    fun emitError(message: String, code: String? = null) {
        val params = Arguments.createMap().apply {
            putString("message", message)
            code?.let { putString("code", it) }
        }
        sendEvent(EVENT_ON_ERROR, params)
    }

    private fun sendEvent(eventName: String, params: WritableMap) {
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(eventName, params)
    }

    // MARK: - Permissions

    private fun hasRecordPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            reactApplicationContext,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestRecordPermission() {
        val activity = currentActivity as? PermissionAwareActivity
        if (activity == null) {
            // No activity available (e.g., app is backgrounded)
            // Reject the promise immediately with a descriptive error
            permissionPromise?.reject(
                "NO_ACTIVITY",
                "Cannot request permission: app activity is not available. Ensure the app is in the foreground."
            )
            permissionPromise = null
            pendingOptions = null
            return
        }
        
        activity.requestPermissions(
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST_CODE,
            this
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val promise = permissionPromise
            val options = pendingOptions ?: DictationOptions()
            
            // Clear stored promise and options in all cases
            permissionPromise = null
            pendingOptions = null
            
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                // Permission granted, start listening with the stored options
                promise?.let { p ->
                    try {
                        coordinator?.startListening(options)
                        p.resolve(null)
                    } catch (e: Exception) {
                        p.reject("START_ERROR", e.message, e)
                    }
                }
            } else {
                // Permission denied
                promise?.reject(
                    "NOT_AUTHORIZED",
                    "Microphone permission denied"
                )
            }
            return true
        }
        return false
    }

    // MARK: - Options Parsing

    private fun parseOptions(map: ReadableMap?): DictationOptions {
        if (map == null) return DictationOptions()
        
        return DictationOptions(
            preserveAudio = map.getBooleanOrDefault("preserveAudio", false),
            preservedAudioFilePath = map.getStringOrNull("preservedAudioFilePath"),
            deleteAudioIfCancelled = map.getBooleanOrDefault("deleteAudioIfCancelled", true)
        )
    }

    private fun ReadableMap.getBooleanOrDefault(key: String, default: Boolean): Boolean {
        return if (hasKey(key)) getBoolean(key) else default
    }

    private fun ReadableMap.getStringOrNull(key: String): String? {
        return if (hasKey(key)) getString(key) else null
    }

    // MARK: - Cleanup

    override fun invalidate() {
        coordinator?.destroy()
        coordinator = null
        super.invalidate()
    }
}

data class DictationOptions(
    val preserveAudio: Boolean = false,
    val preservedAudioFilePath: String? = null,
    val deleteAudioIfCancelled: Boolean = true
)
```

### 3. Dictation Coordinator

**android/src/main/java/com/reactnativedictation/DictationCoordinator.kt**
```kotlin
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
```

### 4. Audio Engine Manager

**android/src/main/java/com/reactnativedictation/AudioEngineManager.kt**
```kotlin
package com.reactnativedictation

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

data class AudioRecordingResult(
    val filePath: String,
    val durationMs: Double,
    val fileSizeBytes: Long,
    val sampleRate: Double,
    val channelCount: Int
)

class AudioEngineManager(private val context: Context) {
    
    companion object {
        const val SAMPLE_RATE = 44100
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var recordingThread: Thread? = null
    
    private var currentAudioLevel: Float = 0f
    private val levelSmoothingFactor = 0.3f
    
    private var encoder: AudioEncoderManager? = null
    private var outputPath: String? = null
    private var totalSamplesRecorded: Long = 0

    fun startRecording(preservationPath: String?) {
        if (isRecording) return

        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT
        )

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT,
            bufferSize * 2
        )

        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            throw Exception("Failed to initialize AudioRecord")
        }

        // Set up encoder if preservation is requested
        preservationPath?.let { path ->
            outputPath = path
            encoder = AudioEncoderManager(context).apply {
                startRecording(path, SAMPLE_RATE, 1)
            }
        }

        totalSamplesRecorded = 0
        isRecording = true
        audioRecord?.startRecording()

        // Start recording thread
        recordingThread = Thread {
            val buffer = ShortArray(bufferSize)
            
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, bufferSize) ?: 0
                
                if (read > 0) {
                    // Calculate audio level
                    val level = calculateAudioLevel(buffer, read)
                    currentAudioLevel = currentAudioLevel * (1 - levelSmoothingFactor) + 
                                       level * levelSmoothingFactor

                    // Write to encoder if active
                    encoder?.writeAudioData(buffer, read)
                    totalSamplesRecorded += read
                }
            }
        }.apply { start() }
    }

    fun stopRecording(deleteFile: Boolean): AudioRecordingResult? {
        isRecording = false
        
        recordingThread?.join(1000)
        recordingThread = null

        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null

        currentAudioLevel = 0f

        val result = encoder?.stopRecording()
        encoder = null

        if (deleteFile && outputPath != null) {
            java.io.File(outputPath!!).delete()
            return null
        }

        return result?.let { encResult ->
            AudioRecordingResult(
                filePath = encResult.canonicalPath,
                durationMs = encResult.durationMs,
                fileSizeBytes = encResult.sizeBytes,
                sampleRate = SAMPLE_RATE.toDouble(),
                channelCount = 1
            )
        }
    }

    fun getAudioLevel(): Float = currentAudioLevel

    private fun calculateAudioLevel(buffer: ShortArray, length: Int): Float {
        if (length == 0) return 0f

        var sumOfSquares = 0.0
        var peak = 0

        for (i in 0 until length) {
            val sample = buffer[i].toInt()
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        val rms = sqrt(sumOfSquares / length).toFloat()
        val normalizedRms = rms / Short.MAX_VALUE

        // Convert to dB
        val dbLevel = 20 * log10(max(normalizedRms, 1e-10f))
        
        // Normalize dB range to 0-1
        val minDb = -75f
        val maxDb = -15f
        val normalizedDb = ((dbLevel - minDb) / (maxDb - minDb)).coerceIn(0f, 1f)

        // Blend with linear components
        val normalizedPeak = (peak.toFloat() / Short.MAX_VALUE).coerceIn(0f, 1f)
        val linearRms = (normalizedRms * 4f).coerceIn(0f, 1f)

        val blended = normalizedDb * 0.55f + linearRms * 0.30f + normalizedPeak * 0.15f
        
        // Shape amplitude
        return blended.toDouble().pow(1.2).toFloat().coerceIn(0f, 1f)
    }

    fun release() {
        isRecording = false
        recordingThread?.join(1000)
        audioRecord?.release()
        audioRecord = null
        encoder = null
    }
}
```

### 5. Audio Encoder Manager

**android/src/main/java/com/reactnativedictation/AudioEncoderManager.kt**
```kotlin
package com.reactnativedictation

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

data class EncodingResult(
    val canonicalPath: String,
    val durationMs: Double,
    val sizeBytes: Long,
    val wasReencoded: Boolean
)

class AudioEncoderManager(private val context: Context) {

    companion object {
        const val SAMPLE_RATE = 44100
        const val CHANNEL_COUNT = 1
        const val BIT_RATE = 64000
        const val MAX_DURATION_MS = 60 * 60 * 1000L // 60 minutes
    }

    private var mediaCodec: MediaCodec? = null
    private var mediaMuxer: MediaMuxer? = null
    private var audioTrackIndex = -1
    private var isEncoding = false
    private var outputPath: String? = null
    private var presentationTimeUs = 0L
    private var totalSamplesEncoded = 0L

    fun startRecording(outputPath: String, sampleRate: Int, channelCount: Int) {
        this.outputPath = outputPath

        // Create output directory if needed
        File(outputPath).parentFile?.mkdirs()

        // Configure encoder
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            SAMPLE_RATE,
            CHANNEL_COUNT
        ).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        }

        mediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }

        mediaMuxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        isEncoding = true
        presentationTimeUs = 0
        totalSamplesEncoded = 0
    }

    fun writeAudioData(buffer: ShortArray, length: Int) {
        if (!isEncoding) return

        val codec = mediaCodec ?: return
        
        // Convert short array to byte buffer
        val byteBuffer = ByteBuffer.allocate(length * 2)
        for (i in 0 until length) {
            byteBuffer.putShort(buffer[i])
        }
        byteBuffer.flip()

        // Get input buffer
        val inputBufferIndex = codec.dequeueInputBuffer(10000)
        if (inputBufferIndex >= 0) {
            val inputBuffer = codec.getInputBuffer(inputBufferIndex) ?: return
            inputBuffer.clear()
            inputBuffer.put(byteBuffer)

            val pts = totalSamplesEncoded * 1_000_000L / SAMPLE_RATE
            codec.queueInputBuffer(inputBufferIndex, 0, length * 2, pts, 0)
            totalSamplesEncoded += length
        }

        // Process output
        drainEncoder(false)
    }

    fun stopRecording(): EncodingResult? {
        if (!isEncoding) return null

        isEncoding = false

        // Signal end of stream
        mediaCodec?.let { codec ->
            val inputBufferIndex = codec.dequeueInputBuffer(10000)
            if (inputBufferIndex >= 0) {
                codec.queueInputBuffer(
                    inputBufferIndex, 0, 0, 0,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                )
            }
        }

        // Drain remaining data
        drainEncoder(true)

        // Stop and release
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) { /* ignore */ }
        mediaCodec = null

        try {
            mediaMuxer?.stop()
            mediaMuxer?.release()
        } catch (e: Exception) { /* ignore */ }
        mediaMuxer = null

        // Return result
        val path = outputPath ?: return null
        val file = File(path)
        
        if (!file.exists()) return null

        val durationMs = totalSamplesEncoded * 1000.0 / SAMPLE_RATE

        return EncodingResult(
            canonicalPath = path,
            durationMs = durationMs,
            sizeBytes = file.length(),
            wasReencoded = true
        )
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val codec = mediaCodec ?: return
        val muxer = mediaMuxer ?: return

        val bufferInfo = MediaCodec.BufferInfo()

        while (true) {
            val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)

            when {
                outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val newFormat = codec.outputFormat
                    audioTrackIndex = muxer.addTrack(newFormat)
                    muxer.start()
                }
                outputBufferIndex >= 0 -> {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex) ?: continue

                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        bufferInfo.size = 0
                    }

                    if (bufferInfo.size > 0 && audioTrackIndex >= 0) {
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(audioTrackIndex, outputBuffer, bufferInfo)
                    }

                    codec.releaseOutputBuffer(outputBufferIndex, false)

                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return
                    }
                }
                else -> {
                    if (endOfStream) return
                    break
                }
            }
        }
    }

    fun normalizeAudio(sourcePath: String): EncodingResult {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            throw Exception("Source file not found: $sourcePath")
        }

        val outputPath = CanonicalAudioStorage.makeRecordingPath(context)
        val outputFile = File(outputPath)
        
        // Ensure output directory exists
        outputFile.parentFile?.mkdirs()

        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var audioTrackIndex = -1
        var muxerStarted = false
        var durationUs = 0L
        var wasReencoded = false

        try {
            extractor.setDataSource(sourcePath)
            
            // Find audio track
            var audioTrackIndexInSource = -1
            var inputFormat: MediaFormat? = null
            
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                
                if (mime.startsWith("audio/")) {
                    audioTrackIndexInSource = i
                    inputFormat = format
                    durationUs = format.getLong(MediaFormat.KEY_DURATION)
                    break
                }
            }
            
            if (audioTrackIndexInSource == -1 || inputFormat == null) {
                throw Exception("No audio track found in source file")
            }
            
            extractor.selectTrack(audioTrackIndexInSource)
            
            // Check if already AAC M4A format
            val inputMime = inputFormat.getString(MediaFormat.KEY_MIME) ?: ""
            val inputSampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val inputChannelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            
            val isAlreadyAAC = inputMime == MediaFormat.MIMETYPE_AUDIO_AAC
            val needsResample = inputSampleRate != SAMPLE_RATE || inputChannelCount != CHANNEL_COUNT
            
            if (isAlreadyAAC && !needsResample && sourcePath.endsWith(".m4a", ignoreCase = true)) {
                // File is already in the correct format, just copy it
                sourceFile.copyTo(outputFile, overwrite = true)
                wasReencoded = false
            } else {
                // Need to transcode
                wasReencoded = true
                
                // Create decoder if needed
                if (!isAlreadyAAC || needsResample) {
                    decoder = MediaCodec.createDecoderByType(inputMime)
                    decoder.configure(inputFormat, null, null, 0)
                    decoder.start()
                }
                
                // Create encoder
                val outputFormat = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC,
                    SAMPLE_RATE,
                    CHANNEL_COUNT
                ).apply {
                    setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
                }
                
                encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                encoder.start()
                
                // Create muxer
                muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                
                val bufferInfo = MediaCodec.BufferInfo()
                var inputEOS = false
                var outputEOS = false
                var presentationTimeUs = 0L
                
                // Process audio data (decoding and encoding pipeline)
                while (!outputEOS) {
                    // Decode input (if decoder exists)
                    if (decoder != null && !inputEOS) {
                        val inputBufferIndex = decoder.dequeueInputBuffer(10000)
                        if (inputBufferIndex >= 0) {
                            val inputBuffer = decoder.getInputBuffer(inputBufferIndex)
                            val sampleSize = extractor.readSampleData(inputBuffer!!, 0)
                            
                            if (sampleSize < 0) {
                                decoder.queueInputBuffer(
                                    inputBufferIndex, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputEOS = true
                            } else {
                                val sampleTime = extractor.sampleTime
                                decoder.queueInputBuffer(
                                    inputBufferIndex, 0, sampleSize, sampleTime, 0
                                )
                                extractor.advance()
                            }
                        }
                        
                        // Get decoded output and feed to encoder
                        val outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 10000)
                        if (outputBufferIndex >= 0) {
                            val outputBuffer = decoder.getOutputBuffer(outputBufferIndex)
                            
                            if (outputBuffer != null && bufferInfo.size > 0) {
                                val encoderInputIndex = encoder.dequeueInputBuffer(10000)
                                if (encoderInputIndex >= 0) {
                                    val encoderInputBuffer = encoder.getInputBuffer(encoderInputIndex)
                                    encoderInputBuffer?.clear()
                                    encoderInputBuffer?.put(outputBuffer)
                                    encoder.queueInputBuffer(
                                        encoderInputIndex, 0, bufferInfo.size,
                                        bufferInfo.presentationTimeUs, 0
                                    )
                                }
                            }
                            
                            decoder.releaseOutputBuffer(outputBufferIndex, false)
                            
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                val encoderInputIndex = encoder.dequeueInputBuffer(10000)
                                if (encoderInputIndex >= 0) {
                                    encoder.queueInputBuffer(
                                        encoderInputIndex, 0, 0, 0,
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                }
                            }
                        }
                    } else if (decoder == null && !inputEOS) {
                        // No decoder needed, feed directly to encoder
                        val inputBufferIndex = encoder.dequeueInputBuffer(10000)
                        if (inputBufferIndex >= 0) {
                            val inputBuffer = encoder.getInputBuffer(inputBufferIndex)
                            val sampleSize = extractor.readSampleData(inputBuffer!!, 0)
                            
                            if (sampleSize < 0) {
                                encoder.queueInputBuffer(
                                    inputBufferIndex, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputEOS = true
                            } else {
                                val sampleTime = extractor.sampleTime
                                encoder.queueInputBuffer(
                                    inputBufferIndex, 0, sampleSize, sampleTime, 0
                                )
                                extractor.advance()
                            }
                        }
                    }
                    
                    // Encode and mux output
                    val encoderOutputIndex = encoder.dequeueOutputBuffer(bufferInfo, 10000)
                    when {
                        encoderOutputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val newFormat = encoder.outputFormat
                            audioTrackIndex = muxer!!.addTrack(newFormat)
                            muxer!!.start()
                            muxerStarted = true
                        }
                        encoderOutputIndex >= 0 -> {
                            val outputBuffer = encoder.getOutputBuffer(encoderOutputIndex)
                            
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                bufferInfo.size = 0
                            }
                            
                            if (bufferInfo.size > 0 && muxerStarted && audioTrackIndex >= 0) {
                                outputBuffer?.position(bufferInfo.offset)
                                outputBuffer?.limit(bufferInfo.offset + bufferInfo.size)
                                muxer!!.writeSampleData(audioTrackIndex, outputBuffer!!, bufferInfo)
                                presentationTimeUs = bufferInfo.presentationTimeUs
                            }
                            
                            encoder.releaseOutputBuffer(encoderOutputIndex, false)
                            
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                outputEOS = true
                            }
                        }
                    }
                }
                
                // Update duration from actual presentation time
                if (presentationTimeUs > 0) {
                    durationUs = presentationTimeUs
                }
            }
        } finally {
            extractor.release()
            decoder?.stop()
            decoder?.release()
            encoder?.stop()
            encoder?.release()
            if (muxerStarted) {
                muxer?.stop()
            }
            muxer?.release()
        }
        
        // Verify output file exists
        if (!outputFile.exists()) {
            throw Exception("Failed to create output file")
        }
        
        val durationMs = if (durationUs > 0) {
            durationUs / 1000.0
        } else {
            // Fallback: estimate from file size if duration unavailable
            val estimatedDurationMs = (outputFile.length() * 8.0) / BIT_RATE * 1000.0
            estimatedDurationMs.coerceAtLeast(100.0) // Minimum 100ms
        }
        
        return EncodingResult(
            canonicalPath = outputPath,
            durationMs = durationMs,
            sizeBytes = outputFile.length(),
            wasReencoded = wasReencoded
        )
    }
}
```

### 6. Canonical Audio Storage

**android/src/main/java/com/reactnativedictation/CanonicalAudioStorage.kt**
```kotlin
package com.reactnativedictation

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.*

object CanonicalAudioStorage {
    
    private const val RECORDINGS_FOLDER = "DictationRecordings"
    
    fun getRecordingsDirectory(context: Context): File {
        val dir = File(context.filesDir, RECORDINGS_FOLDER)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    fun makeRecordingPath(context: Context): String {
        val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH-mm-ss", Locale.US)
        val timestamp = dateFormat.format(Date())
        val suffix = UUID.randomUUID().toString().take(6)
        val filename = "dictation_${timestamp}_$suffix.m4a"
        
        return File(getRecordingsDirectory(context), filename).absolutePath
    }
}
```

## Android Manifest Updates

**android/src/main/AndroidManifest.xml**
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.reactnativedictation">

    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.INTERNET" />
    
    <!-- For speech recognition -->
    <queries>
        <intent>
            <action android:name="android.speech.RecognitionService" />
        </intent>
    </queries>

</manifest>
```

## Permission Handling Behavior

The module handles microphone permission requests with the following guarantees:

1. **Options Preservation**: When `startListening` is called with options (e.g., `preserveAudio: true`) but permission is not yet granted, the options are stored and used when permission is granted. This ensures features like audio preservation and custom file paths are honored on the first attempt.

2. **Null Activity Handling**: If the app is backgrounded or the activity is unavailable when requesting permission, the promise is immediately rejected with error code `NO_ACTIVITY` and a descriptive message. This prevents JS callers from hanging indefinitely.

3. **Promise Resolution**: The permission promise always resolves or rejects—never left hanging. All control paths (granted, denied, no activity) clear the stored promise and options.

4. **Background Behavior**: If the app is backgrounded during a permission request, the module will reject the request. Integrators should ensure the app is in the foreground when requesting microphone permission.

## Verification Checklist

- [ ] `DictationPackage` is registered in `MainApplication`
- [ ] `DictationModule` receives method calls from JS
- [ ] Permission request triggers system dialog
- [ ] Dictation options (e.g., `preserveAudio`) are preserved across permission prompts
- [ ] Permission request rejects immediately with `NO_ACTIVITY` when app is backgrounded
- [ ] Speech recognition works with partial results
- [ ] Audio levels are calculated and emitted
- [ ] Audio encoding produces valid .m4a files
- [ ] Audio normalization returns accurate duration and file size
- [ ] Events are received in JavaScript

## Known Limitations

1. **Offline Support**: Android speech recognition typically requires network
2. **Background Recording**: May be limited on newer Android versions
3. **Device Variability**: Speech recognition quality varies by device/OEM

## Next Steps

Proceed to [09_TESTING_AND_VALIDATION.md](./09_TESTING_AND_VALIDATION.md) for comprehensive testing guidance.
