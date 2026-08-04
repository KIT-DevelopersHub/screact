package com.nxtend.team35.yubiboard

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.nxtend.team35.yubiboard.network.ConnectionConfig
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.network.YubiBoardWebSocketClient
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.settings.AppSettings
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult
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
        mutableMode.value = mode
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
            .apply()
        webSocketClient.setMaxFrameRate(settings.maxSendFps)
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
        private const val DEFAULT_PORT = 8080
    }
}
