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
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult
import java.util.UUID

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences = application.getSharedPreferences(PREFERENCES, 0)
    private val mutableConnection = MutableLiveData(ConnectionSnapshot(ConnectionStatus.DISCONNECTED))
    private val mutableMode = MutableLiveData(CaptureMode.TRACKING)
    private val mutableLog = MutableLiveData<String>()

    val connection: LiveData<ConnectionSnapshot> = mutableConnection
    val mode: LiveData<CaptureMode> = mutableMode
    val log: LiveData<String> = mutableLog
    val savedHost: String get() = preferences.getString(KEY_HOST, "") ?: ""
    val savedPort: Int get() = preferences.getInt(KEY_PORT, DEFAULT_PORT)

    private val webSocketClient = YubiBoardWebSocketClient(
        deviceId = getOrCreateDeviceId(),
        clientVersion = BuildConfig.VERSION_NAME,
        onStateChanged = mutableConnection::postValue,
        onModeChanged = mutableMode::postValue,
        onLog = mutableLog::postValue,
    )

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

    companion object {
        private const val PREFERENCES = "yubiboard_connection"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val DEFAULT_PORT = 8080
    }
}
