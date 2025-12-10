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

            // Parse options first
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
