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
