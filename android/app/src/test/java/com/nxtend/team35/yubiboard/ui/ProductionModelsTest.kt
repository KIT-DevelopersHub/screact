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
    fun `ready visuals distinguish an active hand from idle tracking`() {
        val base = ProductionUiState(
            camera = CameraUiState.READY,
            connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
            captureMode = CaptureMode.TRACKING,
        )

        listOf(
            TrackingUiState.INACTIVE,
            TrackingUiState.READY_NO_HAND,
        ).forEach { tracking ->
            assertEquals(ProductionVisualState.READY_IDLE, base.copy(tracking = tracking).visualState())
        }
        listOf(
            TrackingUiState.CANDIDATE,
            TrackingUiState.TRACKING,
            TrackingUiState.TEMPORARILY_LOST,
            TrackingUiState.LONG_LOST,
        ).forEach { tracking ->
            assertEquals(ProductionVisualState.READY_ACTIVE, base.copy(tracking = tracking).visualState())
        }
    }

    @Test
    fun `only placement-like calibration states use the placement visual`() {
        val base = ProductionUiState(
            camera = CameraUiState.READY,
            connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
            captureMode = CaptureMode.CALIBRATION,
        )

        assertEquals(
            ProductionVisualState.PLACEMENT,
            base.copy(calibration = CalibrationUiState.PlacementWaiting).visualState(),
        )
        listOf(
            CalibrationUiState.Inactive,
            CalibrationUiState.FindingMarkers(2),
            CalibrationUiState.Stabilizing(3, 5),
            CalibrationUiState.WaitingForPc,
            CalibrationUiState.RetryRequired(CalibrationRetryReason.UNSTABLE),
            CalibrationUiState.Complete,
        ).forEach { calibration ->
            assertEquals(
                ProductionVisualState.CALIBRATION_PROGRESS,
                base.copy(calibration = calibration).visualState(),
            )
        }
    }

    @Test
    fun `connection stages keep form progress and reconnect visuals separate`() {
        val base = ProductionUiState(camera = CameraUiState.READY)

        assertEquals(ProductionVisualState.CONNECTION_FORM, base.visualState())
        assertEquals(
            ProductionVisualState.CONNECTION_FORM,
            base.copy(connection = ConnectionSnapshot(ConnectionStatus.ERROR)).visualState(),
        )
        listOf(ConnectionStatus.CONNECTING, ConnectionStatus.AWAITING_ACK).forEach { status ->
            assertEquals(
                ProductionVisualState.CONNECTION_PROGRESS,
                base.copy(connection = ConnectionSnapshot(status, automatic = status == ConnectionStatus.AWAITING_ACK))
                    .visualState(),
            )
        }
        assertEquals(
            ProductionVisualState.RECONNECTING,
            base.copy(connection = ConnectionSnapshot(ConnectionStatus.RECONNECTING)).visualState(),
        )
    }

    @Test
    fun `camera and connection priority also controls visual state`() {
        val active = ProductionUiState(
            camera = CameraUiState.READY,
            connection = ConnectionSnapshot(ConnectionStatus.CONNECTED),
            tracking = TrackingUiState.TRACKING,
        )

        assertEquals(ProductionVisualState.READY_ACTIVE, active.visualState())
        assertEquals(
            ProductionVisualState.RECONNECTING,
            active.copy(connection = ConnectionSnapshot(ConnectionStatus.RECONNECTING)).visualState(),
        )
        assertEquals(
            ProductionVisualState.CALIBRATION_PROGRESS,
            active.copy(
                captureMode = CaptureMode.CALIBRATION,
                calibration = CalibrationUiState.FindingMarkers(1),
            ).visualState(),
        )
        assertEquals(
            ProductionVisualState.CAMERA_ERROR,
            active.copy(camera = CameraUiState.ERROR).visualState(),
        )
        assertEquals(
            ProductionVisualState.CAMERA_PERMISSION,
            active.copy(camera = CameraUiState.PERMISSION_DENIED).visualState(),
        )
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
