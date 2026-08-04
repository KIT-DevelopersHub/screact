package com.nxtend.team35.yubiboard

import android.app.Application
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.nxtend.team35.yubiboard.network.ConnectionConfig
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.network.YubiBoardWebSocketClient
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.settings.AppSettings
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult
import com.nxtend.team35.yubiboard.vision.DetectedMarker
import com.nxtend.team35.yubiboard.vision.LandmarkPoint
import com.nxtend.team35.yubiboard.vision.NormalizedPoint
import java.util.UUID

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences(PREFERENCES, 0)
    private val mutableConnection = MutableLiveData(ConnectionSnapshot(ConnectionStatus.DISCONNECTED))
    private val mutableMode = MutableLiveData(CaptureMode.TRACKING)
    private val mutableLog = MutableLiveData<String>()
    private val mutableSettings = MutableLiveData(loadSettings())

    val connection: LiveData<ConnectionSnapshot> = mutableConnection
    val mode: LiveData<CaptureMode> = mutableMode
    val log: LiveData<String> = mutableLog
    val settings: LiveData<AppSettings> = mutableSettings
    val currentSettings: AppSettings get() = mutableSettings.value ?: AppSettings()
    val savedHost: String get() = preferences.getString(KEY_HOST, "") ?: ""
    val savedPort: Int get() = preferences.getInt(KEY_PORT, DEFAULT_PORT)

    private val webSocketClient = YubiBoardWebSocketClient(
        deviceId = getOrCreateDeviceId(),
        clientVersion = BuildConfig.VERSION_NAME,
        onStateChanged = mutableConnection::postValue,
        onModeChanged = mutableMode::postValue,
        onLog = mutableLog::postValue,
    )

    init {
        webSocketClient.setMaxFrameRate(currentSettings.maxSendFps)
        AppDiagnostics.setEnabled(currentSettings.debugModeEnabled)
    }

    fun connect(host: String, portText: String, pairingToken: String): String? {
        val port = portText.toIntOrNull() ?: return "ポートは数字で入力してください"
        val config = ConnectionConfig(host.trim(), port, pairingToken.trim())
        config.validate()?.let { return it }
        preferences.edit()
            .putString(KEY_HOST, config.host)
            .putInt(KEY_PORT, config.port)
            .apply()
        webSocketClient.connect(config)
        return null
    }

    fun disconnect() = webSocketClient.disconnect()

    fun submitHand(result: HandDetectionResult) = webSocketClient.submitHand(result)

    fun submitCalibration(result: MarkerDetectionResult) = webSocketClient.submitCalibration(result)

    fun setModeManually(mode: CaptureMode) {
        AppDiagnostics.event("ui", "manual_mode", mapOf("mode" to mode))
        mutableMode.value = mode
    }

    fun submitDebugHand(detected: Boolean) {
        check(currentSettings.debugModeEnabled) { "Debug mode is disabled" }
        val landmarks = if (detected) List(21) { index ->
            LandmarkPoint(
                x = 0.3f + (index % 5) * 0.08f,
                y = 0.25f + (index / 5) * 0.12f,
                z = -index * 0.001f,
            )
        } else emptyList()
        AppDiagnostics.event("debug", "synthetic_hand", mapOf("detected" to detected))
        submitHand(
            HandDetectionResult(
                capturedAtMonotonicMs = SystemClock.uptimeMillis(),
                sourceWidth = currentSettings.analysisWidth,
                sourceHeight = currentSettings.analysisHeight,
                detected = detected,
                landmarks = landmarks,
                handedness = if (detected) "RIGHT" else null,
                handednessScore = if (detected) 0.99f else null,
            ),
        )
    }

    fun submitDebugCalibration() {
        check(currentSettings.debugModeEnabled) { "Debug mode is disabled" }
        fun marker(id: Int, x: Float, y: Float) = DetectedMarker(
            id = id,
            center = NormalizedPoint(x, y),
            corners = listOf(
                NormalizedPoint(x - 0.03f, y - 0.03f),
                NormalizedPoint(x + 0.03f, y - 0.03f),
                NormalizedPoint(x + 0.03f, y + 0.03f),
                NormalizedPoint(x - 0.03f, y + 0.03f),
            ),
        )
        AppDiagnostics.event("debug", "synthetic_calibration")
        submitCalibration(
            MarkerDetectionResult(
                capturedAtMonotonicMs = SystemClock.uptimeMillis(),
                sourceWidth = currentSettings.analysisWidth,
                sourceHeight = currentSettings.analysisHeight,
                markers = listOf(
                    marker(10, 0.1f, 0.1f),
                    marker(11, 0.9f, 0.1f),
                    marker(12, 0.9f, 0.9f),
                    marker(13, 0.1f, 0.9f),
                ),
                stable = true,
            ),
        )
    }

    fun updateSettings(settings: AppSettings): String? {
        settings.validate()?.let { return it }
        preferences.edit()
            .putInt(KEY_ANALYSIS_WIDTH, settings.analysisWidth)
            .putInt(KEY_ANALYSIS_HEIGHT, settings.analysisHeight)
            .putFloat(KEY_DETECTION_CONFIDENCE, settings.minDetectionConfidence)
            .putFloat(KEY_PRESENCE_CONFIDENCE, settings.minPresenceConfidence)
            .putFloat(KEY_TRACKING_CONFIDENCE, settings.minTrackingConfidence)
            .putInt(KEY_MAX_SEND_FPS, settings.maxSendFps)
            .putBoolean(KEY_DEBUG_MODE, settings.debugModeEnabled)
            .apply()
        webSocketClient.setMaxFrameRate(settings.maxSendFps)
        AppDiagnostics.setEnabled(settings.debugModeEnabled)
        mutableSettings.value = settings
        return null
    }

    override fun onCleared() {
        webSocketClient.close()
        super.onCleared()
    }

    private fun getOrCreateDeviceId(): String {
        preferences.getString(KEY_DEVICE_ID, null)?.let { return it }
        val deviceId = "android-${UUID.randomUUID().toString().take(8)}"
        preferences.edit().putString(KEY_DEVICE_ID, deviceId).apply()
        return deviceId
    }

    private fun loadSettings() = AppSettings(
        analysisWidth = preferences.getInt(KEY_ANALYSIS_WIDTH, 640),
        analysisHeight = preferences.getInt(KEY_ANALYSIS_HEIGHT, 480),
        minDetectionConfidence = preferences.getFloat(KEY_DETECTION_CONFIDENCE, 0.5f),
        minPresenceConfidence = preferences.getFloat(KEY_PRESENCE_CONFIDENCE, 0.5f),
        minTrackingConfidence = preferences.getFloat(KEY_TRACKING_CONFIDENCE, 0.5f),
        maxSendFps = preferences.getInt(KEY_MAX_SEND_FPS, 20),
        debugModeEnabled = preferences.getBoolean(KEY_DEBUG_MODE, BuildConfig.DEBUG),
    ).let { if (it.validate() == null) it else AppSettings() }

    companion object {
        private const val PREFERENCES = "yubiboard_connection"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val KEY_ANALYSIS_WIDTH = "analysis_width"
        private const val KEY_ANALYSIS_HEIGHT = "analysis_height"
        private const val KEY_DETECTION_CONFIDENCE = "detection_confidence"
        private const val KEY_PRESENCE_CONFIDENCE = "presence_confidence"
        private const val KEY_TRACKING_CONFIDENCE = "tracking_confidence"
        private const val KEY_MAX_SEND_FPS = "max_send_fps"
        private const val KEY_DEBUG_MODE = "debug_mode"
        private const val DEFAULT_PORT = 8080
    }
}
