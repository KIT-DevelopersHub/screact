package com.nxtend.team35.yubiboard

import android.app.Application
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import android.content.Context
import android.net.wifi.WifiManager
import com.nxtend.team35.yubiboard.network.ConnectionConfig
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.network.DesktopDiscoveryListener
import com.nxtend.team35.yubiboard.network.YubiBoardWebSocketClient
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.protocol.CalibrationStatusMessage
import com.nxtend.team35.yubiboard.settings.AppSettings
import com.nxtend.team35.yubiboard.ui.CalibrationRetryReason
import com.nxtend.team35.yubiboard.ui.CalibrationUiState
import com.nxtend.team35.yubiboard.ui.CameraUiState
import com.nxtend.team35.yubiboard.ui.ExperienceMode
import com.nxtend.team35.yubiboard.ui.PairingUiState
import com.nxtend.team35.yubiboard.ui.ProductionUiState
import com.nxtend.team35.yubiboard.ui.TrackingUiState
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
    private var productionSnapshot = ProductionUiState(
        experience = if (mutableSettings.value?.debugModeEnabled == true) {
            ExperienceMode.DEBUG
        } else {
            ExperienceMode.PRODUCTION
        },
    )
    private val mutableProductionState = MutableLiveData(productionSnapshot)
    private val mutableCalibrationReset = MutableLiveData<Long>()

    val connection: LiveData<ConnectionSnapshot> = mutableConnection
    val mode: LiveData<CaptureMode> = mutableMode
    val log: LiveData<String> = mutableLog
    val settings: LiveData<AppSettings> = mutableSettings
    val productionState: LiveData<ProductionUiState> = mutableProductionState
    val calibrationReset: LiveData<Long> = mutableCalibrationReset
    val currentSettings: AppSettings get() = mutableSettings.value ?: AppSettings()
    val savedHost: String get() = preferences.getString(KEY_HOST, "") ?: ""
    val savedPort: Int get() = preferences.getInt(KEY_PORT, DEFAULT_PORT)

    private val deviceId = getOrCreateDeviceId()

    private val webSocketClient = YubiBoardWebSocketClient(
        deviceId = deviceId,
        clientVersion = BuildConfig.VERSION_NAME,
        onStateChanged = ::handleConnectionChanged,
        onModeChanged = ::handleModeChanged,
        onCalibrationStatus = ::handleCalibrationStatus,
        onLog = mutableLog::postValue,
    )

    @Volatile
    private var discoveryListener: DesktopDiscoveryListener? = null

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

    /**
     * 「画面認識開始」: デスクトップのUDPブロードキャストの待受を開始する。
     * デスクトップに選択されると自動で WebSocket 接続する（IP/コード入力なし）。
     */
    fun startAutoPairing() {
        if (discoveryListener?.isRunning == true) return
        val listener = DesktopDiscoveryListener(
            deviceId = deviceId,
            deviceName = android.os.Build.MODEL.ifBlank { "Android" },
            model = android.os.Build.MODEL.ifBlank { "Android" },
            onSelected = ::onDesktopSelected,
            onLog = mutableLog::postValue,
            multicastLock = createMulticastLock(),
        )
        val error = runCatching { listener.start() }.exceptionOrNull()
        if (error != null) {
            AppDiagnostics.event("discovery", "listen_failed", mapOf("message" to error.message))
            mutableLog.postValue("自動検出を開始できませんでした。手動接続をお試しください")
            return
        }
        discoveryListener = listener
        updateProduction { it.copy(pairing = PairingUiState.WAITING) }
    }

    /** 待受のキャンセル（「画面認識開始」前の状態に戻す）。 */
    fun cancelAutoPairing() {
        stopDiscovery()
        updateProduction { it.copy(pairing = PairingUiState.IDLE) }
    }

    private fun onDesktopSelected(host: String, wsPort: Int, token: String) {
        stopDiscovery()
        updateProduction { it.copy(pairing = PairingUiState.IDLE) }
        connect(host, wsPort.toString(), token)?.let { error ->
            mutableLog.postValue(error)
        }
    }

    private fun stopDiscovery() {
        discoveryListener?.stop()
        discoveryListener = null
    }

    private fun createMulticastLock(): DesktopDiscoveryListener.Lock? = runCatching {
        val wifi = getApplication<Application>()
            .applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("screact-discovery").apply { setReferenceCounted(false) }
        object : DesktopDiscoveryListener.Lock {
            override fun acquire() = lock.acquire()
            override fun release() {
                if (lock.isHeld) lock.release()
            }
        }
    }.getOrNull()

    fun disconnect() {
        stopDiscovery()
        updateProduction { it.copy(pairing = PairingUiState.IDLE) }
        webSocketClient.disconnect()
    }

    fun retryNow() = webSocketClient.retryNow()

    fun onNetworkLost() = webSocketClient.onNetworkLost()

    fun onNetworkAvailable() = webSocketClient.onNetworkAvailable()

    fun changeConnectionSettings() {
        stopDiscovery()
        webSocketClient.disconnect()
        updateProduction {
            it.copy(
                connection = ConnectionSnapshot(ConnectionStatus.DISCONNECTED),
                calibration = CalibrationUiState.Inactive,
                tracking = TrackingUiState.INACTIVE,
                pairing = PairingUiState.IDLE,
            )
        }
    }

    fun updateCameraState(state: CameraUiState, notice: String? = null) {
        updateProduction { it.copy(camera = state, notice = notice) }
    }

    fun submitHand(result: HandDetectionResult) {
        webSocketClient.submitHand(result)
        updateProduction { current ->
            if (current.captureMode != CaptureMode.TRACKING) return@updateProduction current
            val nextTracking = when (result.trackingState) {
                com.nxtend.team35.yubiboard.vision.TrackingState.CANDIDATE -> TrackingUiState.CANDIDATE
                com.nxtend.team35.yubiboard.vision.TrackingState.TRACKING -> TrackingUiState.TRACKING
                com.nxtend.team35.yubiboard.vision.TrackingState.TEMPORARILY_LOST ->
                    TrackingUiState.TEMPORARILY_LOST
                com.nxtend.team35.yubiboard.vision.TrackingState.UNDETECTED -> {
                    if (current.tracking in setOf(
                            TrackingUiState.TRACKING,
                            TrackingUiState.TEMPORARILY_LOST,
                            TrackingUiState.LONG_LOST,
                        )
                    ) {
                        TrackingUiState.LONG_LOST
                    } else {
                        TrackingUiState.READY_NO_HAND
                    }
                }
            }
            current.copy(
                tracking = nextTracking,
                indexTip = result.landmarks.getOrNull(8),
                sourceWidth = result.sourceWidth,
                sourceHeight = result.sourceHeight,
            )
        }
    }

    fun submitCalibration(result: MarkerDetectionResult) {
        if (result.stable) webSocketClient.submitCalibration(result)
        updateProduction { current ->
            if (current.captureMode != CaptureMode.CALIBRATION) return@updateProduction current
            val calibration = when {
                result.stable -> CalibrationUiState.WaitingForPc
                result.markers.size < 4 -> CalibrationUiState.FindingMarkers(result.markers.size)
                else -> CalibrationUiState.Stabilizing(
                    result.stableFrameCount,
                    result.requiredStableFrames,
                )
            }
            current.copy(
                calibration = calibration,
                markers = result.markers,
                sourceWidth = result.sourceWidth,
                sourceHeight = result.sourceHeight,
            )
        }
    }

    fun setModeManually(mode: CaptureMode) {
        AppDiagnostics.event("ui", "manual_mode", mapOf("mode" to mode))
        handleModeChanged(mode)
    }

    fun setExperienceMode(mode: ExperienceMode) {
        if (!BuildConfig.DEBUG && mode == ExperienceMode.DEBUG) return
        val debugEnabled = mode == ExperienceMode.DEBUG
        val updated = currentSettings.copy(debugModeEnabled = debugEnabled)
        preferences.edit().putBoolean(KEY_DEBUG_MODE, debugEnabled).apply()
        AppDiagnostics.setEnabled(debugEnabled)
        mutableSettings.value = updated
        updateProduction { it.copy(experience = mode) }
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

    private fun handleConnectionChanged(snapshot: ConnectionSnapshot) {
        mutableConnection.postValue(snapshot)
        updateProduction { current ->
            val resetCaptureState = snapshot.status !in setOf(ConnectionStatus.CONNECTED)
            current.copy(
                connection = snapshot,
                calibration = if (resetCaptureState) CalibrationUiState.Inactive else current.calibration,
                tracking = if (resetCaptureState) TrackingUiState.INACTIVE else current.tracking,
            )
        }
    }

    private fun handleModeChanged(mode: CaptureMode) {
        mutableMode.postValue(mode)
        if (mode == CaptureMode.CALIBRATION) mutableCalibrationReset.postValue(SystemClock.uptimeMillis())
        updateProduction { current ->
            if (mode == CaptureMode.CALIBRATION) {
                current.copy(
                    captureMode = mode,
                    calibration = CalibrationUiState.FindingMarkers(0),
                    tracking = TrackingUiState.INACTIVE,
                    markers = emptyList(),
                    indexTip = null,
                )
            } else {
                current.copy(
                    captureMode = mode,
                    calibration = CalibrationUiState.Complete,
                    tracking = TrackingUiState.READY_NO_HAND,
                    markers = emptyList(),
                )
            }
        }
    }

    private fun handleCalibrationStatus(message: CalibrationStatusMessage) {
        val state = when (message.status) {
            "processing" -> CalibrationUiState.WaitingForPc
            "complete" -> CalibrationUiState.Complete
            "retry_required" -> CalibrationUiState.RetryRequired(
                when (message.reason) {
                    "markers_not_visible" -> CalibrationRetryReason.MARKERS_NOT_VISIBLE
                    "invalid_geometry" -> CalibrationRetryReason.INVALID_GEOMETRY
                    "unstable" -> CalibrationRetryReason.UNSTABLE
                    "screen_mismatch" -> CalibrationRetryReason.SCREEN_MISMATCH
                    "internal_error" -> CalibrationRetryReason.INTERNAL_ERROR
                    else -> CalibrationRetryReason.UNKNOWN
                },
            )
            else -> return
        }
        if (state is CalibrationUiState.RetryRequired) {
            mutableCalibrationReset.postValue(SystemClock.uptimeMillis())
        }
        updateProduction { it.copy(calibration = state) }
    }

    @Synchronized
    private fun updateProduction(transform: (ProductionUiState) -> ProductionUiState) {
        productionSnapshot = transform(productionSnapshot)
        mutableProductionState.postValue(productionSnapshot)
    }

    fun updateSettings(settings: AppSettings): String? {
        val effective = if (BuildConfig.DEBUG) settings else settings.copy(debugModeEnabled = false)
        effective.validate()?.let { return it }
        preferences.edit()
            .putInt(KEY_ANALYSIS_WIDTH, effective.analysisWidth)
            .putInt(KEY_ANALYSIS_HEIGHT, effective.analysisHeight)
            .putFloat(KEY_DETECTION_CONFIDENCE, effective.minDetectionConfidence)
            .putFloat(KEY_PRESENCE_CONFIDENCE, effective.minPresenceConfidence)
            .putFloat(KEY_TRACKING_CONFIDENCE, effective.minTrackingConfidence)
            .putInt(KEY_MAX_SEND_FPS, effective.maxSendFps)
            .putBoolean(KEY_DEBUG_MODE, effective.debugModeEnabled)
            .apply()
        webSocketClient.setMaxFrameRate(effective.maxSendFps)
        AppDiagnostics.setEnabled(effective.debugModeEnabled)
        mutableSettings.value = effective
        updateProduction {
            it.copy(
                experience = if (effective.debugModeEnabled) ExperienceMode.DEBUG else ExperienceMode.PRODUCTION,
            )
        }
        return null
    }

    override fun onCleared() {
        stopDiscovery()
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
        analysisWidth = preferences.getInt(KEY_ANALYSIS_WIDTH, 1280),
        analysisHeight = preferences.getInt(KEY_ANALYSIS_HEIGHT, 720),
        minDetectionConfidence = preferences.getFloat(KEY_DETECTION_CONFIDENCE, 0.5f),
        minPresenceConfidence = preferences.getFloat(KEY_PRESENCE_CONFIDENCE, 0.5f),
        minTrackingConfidence = preferences.getFloat(KEY_TRACKING_CONFIDENCE, 0.5f),
        maxSendFps = preferences.getInt(KEY_MAX_SEND_FPS, 20),
        debugModeEnabled = BuildConfig.DEBUG && preferences.getBoolean(KEY_DEBUG_MODE, true),
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
        // デスクトップ側サーバの既定ポート（desktop/lib/ui/home_page.dart と一致させる）
        private const val DEFAULT_PORT = 8765
    }
}
