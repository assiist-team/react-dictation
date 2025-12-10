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
                
                // Process audio data
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
                        
                        // Get decoded output
                        val outputBufferIndex = decoder.dequeueOutputBuffer(bufferInfo, 10000)
                        if (outputBufferIndex >= 0) {
                            val outputBuffer = decoder.getOutputBuffer(outputBufferIndex)
                            
                            if (outputBuffer != null && bufferInfo.size > 0) {
                                // Feed decoded data to encoder
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
                                // Signal end of stream to encoder
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
            // This is a rough estimate and not accurate
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
