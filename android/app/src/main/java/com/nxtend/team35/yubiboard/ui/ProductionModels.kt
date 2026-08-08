package com.nxtend.team35.yubiboard.ui

import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.vision.DetectedMarker
import com.nxtend.team35.yubiboard.vision.LandmarkPoint
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult

enum class CameraUiState {
    PERMISSION_REQUIRED,
    PERMISSION_DENIED,
    STARTING,
    READY,
    ERROR,
}

sealed interface CalibrationUiState {
    data object Inactive : CalibrationUiState
    data object PlacementWaiting : CalibrationUiState
    data class FindingMarkers(val found: Int) : CalibrationUiState
    data class Stabilizing(val current: Int, val required: Int) : CalibrationUiState
    data object WaitingForPc : CalibrationUiState
    data class RetryRequired(val reason: CalibrationRetryReason) : CalibrationUiState
    data object Complete : CalibrationUiState
}

fun calibrationUiStateAfterFrame(
    current: CalibrationUiState,
    result: MarkerDetectionResult,
): CalibrationUiState = when {
    current in setOf(CalibrationUiState.WaitingForPc, CalibrationUiState.Complete) -> current
    result.stable -> CalibrationUiState.WaitingForPc
    current == CalibrationUiState.PlacementWaiting && result.markers.isEmpty() ->
        CalibrationUiState.PlacementWaiting
    current is CalibrationUiState.RetryRequired && result.markers.isEmpty() -> current
    result.markers.size < 4 -> CalibrationUiState.FindingMarkers(result.markers.size)
    else -> CalibrationUiState.Stabilizing(result.stableFrameCount, result.requiredStableFrames)
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
    AUTO_CONNECTING,
    CONNECTION_ERROR,
    RECONNECTING,
    CALIBRATION,
    READY,
}

/**
 * Visual families used by the production guide panel.
 *
 * Keeping this mapping separate from the composables makes the redesigned UI follow the
 * existing connection/calibration/tracking state machine without introducing a second source
 * of truth for app behaviour.
 */
enum class ProductionVisualState {
    CAMERA_PERMISSION,
    CAMERA_ERROR,
    CONNECTION_FORM,
    CONNECTION_PROGRESS,
    RECONNECTING,
    PLACEMENT,
    CALIBRATION_PROGRESS,
    READY_IDLE,
    READY_ACTIVE,
}

fun ProductionUiState.stage(): ProductionStage = when {
    camera == CameraUiState.PERMISSION_REQUIRED || camera == CameraUiState.PERMISSION_DENIED ->
        ProductionStage.CAMERA_PERMISSION
    camera == CameraUiState.ERROR -> ProductionStage.CAMERA_ERROR
    connection.status == ConnectionStatus.ERROR -> ProductionStage.CONNECTION_ERROR
    connection.status == ConnectionStatus.RECONNECTING -> ProductionStage.RECONNECTING
    connection.status in setOf(ConnectionStatus.CONNECTING, ConnectionStatus.AWAITING_ACK) ->
        if (connection.automatic) ProductionStage.AUTO_CONNECTING else ProductionStage.CONNECTING
    connection.status == ConnectionStatus.DISCONNECTED -> ProductionStage.CONNECT
    captureMode == CaptureMode.CALIBRATION -> ProductionStage.CALIBRATION
    else -> ProductionStage.READY
}

fun ProductionUiState.visualState(): ProductionVisualState = when (stage()) {
    ProductionStage.CAMERA_PERMISSION -> ProductionVisualState.CAMERA_PERMISSION
    ProductionStage.CAMERA_ERROR -> ProductionVisualState.CAMERA_ERROR
    ProductionStage.CONNECT, ProductionStage.CONNECTION_ERROR ->
        ProductionVisualState.CONNECTION_FORM
    ProductionStage.CONNECTING, ProductionStage.AUTO_CONNECTING ->
        ProductionVisualState.CONNECTION_PROGRESS
    ProductionStage.RECONNECTING -> ProductionVisualState.RECONNECTING
    ProductionStage.CALIBRATION -> when (calibration) {
        CalibrationUiState.PlacementWaiting -> ProductionVisualState.PLACEMENT
        else -> ProductionVisualState.CALIBRATION_PROGRESS
    }
    ProductionStage.READY -> when (tracking) {
        TrackingUiState.CANDIDATE,
        TrackingUiState.TRACKING,
        TrackingUiState.TEMPORARILY_LOST,
        TrackingUiState.LONG_LOST -> ProductionVisualState.READY_ACTIVE
        else -> ProductionVisualState.READY_IDLE
    }
}
