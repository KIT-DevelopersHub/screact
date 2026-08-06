package com.nxtend.team35.yubiboard.ui

import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import org.junit.Assert.assertEquals
import org.junit.Test
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult

class ProductionModelsTest {
    @Test
    fun `camera and connection failures take priority over capture state`() {
        val calibration = ProductionUiState(
            camera = CameraUiState.READY,
            connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
            captureMode = CaptureMode.CALIBRATION,
            calibration = CalibrationUiState.FindingMarkers(2),
        )

        assertEquals(ProductionStage.CALIBRATION, calibration.stage())
        assertEquals(
            ProductionStage.RECONNECTING,
            calibration.copy(
                connection = ConnectionSnapshot(ConnectionStatus.RECONNECTING, retryInSeconds = 3),
            ).stage(),
        )
        assertEquals(
            ProductionStage.CAMERA_ERROR,
            calibration.copy(camera = CameraUiState.ERROR).stage(),
        )
    }

    @Test
    fun `tracking is ready only after connected tracking mode`() {
        val state = ProductionUiState(
            camera = CameraUiState.READY,
            connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
            captureMode = CaptureMode.TRACKING,
            tracking = TrackingUiState.READY_NO_HAND,
        )

        assertEquals(ProductionStage.READY, state.stage())
    }

    @Test
    fun `automatic connection has its own production stage`() {
        val state = ProductionUiState(
            camera = CameraUiState.READY,
            connection = ConnectionSnapshot(ConnectionStatus.CONNECTING, automatic = true),
        )

        assertEquals(ProductionStage.AUTO_CONNECTING, state.stage())
    }

    @Test
    fun `calibration progresses from placement through markers and pc confirmation`() {
        val empty = MarkerDetectionResult(1, 1280, 720, emptyList(), stable = false)
        val oneMarker = empty.copy(markers = listOf(sampleMarker(10)))
        val stabilizing = empty.copy(
            markers = listOf(10, 11, 12, 13).map(::sampleMarker),
            stableFrameCount = 3,
            requiredStableFrames = 5,
        )
        val stable = stabilizing.copy(stable = true, stableFrameCount = 5)

        val placement = calibrationUiStateAfterFrame(CalibrationUiState.PlacementWaiting, empty)
        val finding = calibrationUiStateAfterFrame(placement, oneMarker)
        val stableProgress = calibrationUiStateAfterFrame(finding, stabilizing)
        val waitingForPc = calibrationUiStateAfterFrame(stableProgress, stable)

        assertEquals(CalibrationUiState.PlacementWaiting, placement)
        assertEquals(CalibrationUiState.FindingMarkers(1), finding)
        assertEquals(CalibrationUiState.Stabilizing(3, 5), stableProgress)
        assertEquals(CalibrationUiState.WaitingForPc, waitingForPc)
        assertEquals(
            ProductionStage.READY,
            ProductionUiState(
                camera = CameraUiState.READY,
                connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
                captureMode = CaptureMode.TRACKING,
                calibration = CalibrationUiState.Complete,
            ).stage(),
        )
    }

    private fun sampleMarker(id: Int) = com.nxtend.team35.yubiboard.vision.DetectedMarker(
        id = id,
        center = com.nxtend.team35.yubiboard.vision.NormalizedPoint(0.5f, 0.5f),
        corners = List(4) { com.nxtend.team35.yubiboard.vision.NormalizedPoint(0.5f, 0.5f) },
    )
}
