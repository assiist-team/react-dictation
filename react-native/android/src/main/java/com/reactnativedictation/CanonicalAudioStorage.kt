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
