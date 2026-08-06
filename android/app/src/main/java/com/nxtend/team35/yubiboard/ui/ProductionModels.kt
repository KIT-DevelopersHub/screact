package com.nxtend.team35.yubiboard.ui

import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.vision.DetectedMarker
import com.nxtend.team35.yubiboard.vision.LandmarkPoint

enum class ExperienceMode { PRODUCTION, DEBUG }

enum class CameraUiState {
    PERMISSION_REQUIRED,
    PERMISSION_DENIED,
    STARTING,
    READY,
    ERROR,
}

sealed interface CalibrationUiState {
    data object Inactive : CalibrationUiState
    data class FindingMarkers(val found: Int) : CalibrationUiState
    data class Stabilizing(val current: Int, val required: Int) : CalibrationUiState
    data object WaitingForPc : CalibrationUiState
    data class RetryRequired(val reason: CalibrationRetryReason) : CalibrationUiState
    data object Complete : CalibrationUiState
}

enum class CalibrationRetryReason {
    MARKERS_NOT_VISIBLE,
    INVALID_GEOMETRY,
    UNSTABLE,
    SCREEN_MISMATCH,
    INTERNAL_ERROR,
    UNKNOWN,
}

enum class TrackingUiState {
    INACTIVE,
    READY_NO_HAND,
    CANDIDATE,
    TRACKING,
    TEMPORARILY_LOST,
    LONG_LOST,
}

data class ProductionUiState(
    val camera: CameraUiState = CameraUiState.STARTING,
    val connection: ConnectionSnapshot = ConnectionSnapshot(ConnectionStatus.DISCONNECTED),
    val captureMode: CaptureMode = CaptureMode.TRACKING,
    val calibration: CalibrationUiState = CalibrationUiState.Inactive,
    val tracking: TrackingUiState = TrackingUiState.INACTIVE,
    val experience: ExperienceMode = ExperienceMode.PRODUCTION,
    val indexTip: LandmarkPoint? = null,
    val markers: List<DetectedMarker> = emptyList(),
    val sourceWidth: Int = 0,
    val sourceHeight: Int = 0,
    val notice: String? = null,
)

enum class ProductionStage {
    CAMERA_PERMISSION,
    CAMERA_ERROR,
    CONNECT,
    CONNECTING,
    CONNECTION_ERROR,
    RECONNECTING,
    CALIBRATION,
    READY,
}

fun ProductionUiState.stage(): ProductionStage = when {
    camera == CameraUiState.PERMISSION_REQUIRED || camera == CameraUiState.PERMISSION_DENIED ->
        ProductionStage.CAMERA_PERMISSION
    camera == CameraUiState.ERROR -> ProductionStage.CAMERA_ERROR
    connection.status == ConnectionStatus.ERROR -> ProductionStage.CONNECTION_ERROR
    connection.status == ConnectionStatus.RECONNECTING -> ProductionStage.RECONNECTING
    connection.status in setOf(ConnectionStatus.CONNECTING, ConnectionStatus.AWAITING_ACK) ->
        ProductionStage.CONNECTING
    connection.status == ConnectionStatus.DISCONNECTED -> ProductionStage.CONNECT
    captureMode == CaptureMode.CALIBRATION -> ProductionStage.CALIBRATION
    else -> ProductionStage.READY
}
