package com.nxtend.team35.yubiboard.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

const val SCHEMA_VERSION = 1

@Serializable
data class HelloMessage(
    val schemaVersion: Int = SCHEMA_VERSION,
    val messageType: String = "hello",
    val deviceId: String,
    val client: String = "yubiboard-android",
    val clientVersion: String,
    val pairingToken: String? = null,
    val resumeToken: String? = null,
    val interactionProfile: String = "single_user_single_active_hand",
    val coordinateSpace: String = "normalized_camera",
    val capabilities: List<String> = listOf(
        "aruco_calibration",
        "hand_landmarks_21",
        "calibration_status",
        "hello_error",
        "trusted_reconnect",
    ),
) {
    init {
        require((pairingToken != null) xor (resumeToken != null)) {
            "Exactly one of pairingToken or resumeToken is required"
        }
        require(pairingToken == null || pairingToken.matches(Regex("^[0-9]{6}$"))) {
            "pairingToken must be six digits"
        }
        require(resumeToken == null || resumeToken.isNotBlank()) {
            "resumeToken must not be blank"
        }
    }
}

@Serializable
data class SourceInfo(
    val width: Int,
    val height: Int,
    val rotationDegrees: Int = 0,
    val rotationCorrected: Boolean = true,
    val mirrorCorrected: Boolean = true,
)

@Serializable
data class HandPayload(
    val detected: Boolean,
    val handedness: String? = null,
    val handednessScore: Float? = null,
    val coordinateSpace: String? = if (detected) "normalized_camera" else null,
    val landmarkFormat: String? = if (detected) "mediapipe_hand_21" else null,
    val landmarks: List<List<Float>>? = null,
)

@Serializable
data class HandFrameMessage(
    val schemaVersion: Int = SCHEMA_VERSION,
    val messageType: String = "hand_frame",
    val sessionId: String,
    val frameId: Long,
    val capturedAtMonotonicMs: Long,
    val source: SourceInfo? = null,
    val hand: HandPayload,
)

@Serializable
data class MarkerPayload(
    val id: Int,
    val center: List<Float>,
    val corners: List<List<Float>>,
)

@Serializable
data class CalibrationMarkersMessage(
    val schemaVersion: Int = SCHEMA_VERSION,
    val messageType: String = "calibration_markers",
    val sessionId: String,
    val capturedAtMonotonicMs: Long,
    val source: SourceInfo,
    val markers: List<MarkerPayload>,
)

@Serializable
data class HeartbeatMessage(
    val schemaVersion: Int = SCHEMA_VERSION,
    val messageType: String = "heartbeat",
    val sessionId: String,
    val sentAtMonotonicMs: Long,
)

sealed interface ServerMessage

@Serializable
data class SurfaceInfo(
    val surfaceId: String,
    val widthPx: Int,
    val heightPx: Int,
)

@Serializable
data class HelloAckMessage(
    val schemaVersion: Int,
    val messageType: String,
    val sessionId: String,
    val surface: SurfaceInfo,
    val calibrationRequired: Boolean,
    val resumeToken: String? = null,
) : ServerMessage

@Serializable
data class ControlMessage(
    val schemaVersion: Int,
    val messageType: String,
    val sessionId: String,
    val command: String,
    val mode: String? = null,
) : ServerMessage

@Serializable
data class HelloErrorMessage(
    val schemaVersion: Int,
    val messageType: String,
    val code: String,
    val retryable: Boolean = false,
) : ServerMessage

@Serializable
data class CalibrationStatusMessage(
    val schemaVersion: Int,
    val messageType: String,
    val sessionId: String,
    val status: String,
    val reason: String? = null,
) : ServerMessage

enum class CaptureMode {
    @SerialName("tracking")
    TRACKING,

    @SerialName("calibration")
    CALIBRATION,
}
