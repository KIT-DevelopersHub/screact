package com.nxtend.team35.yubiboard.ui

import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import org.junit.Assert.assertEquals
import org.junit.Test

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
}
