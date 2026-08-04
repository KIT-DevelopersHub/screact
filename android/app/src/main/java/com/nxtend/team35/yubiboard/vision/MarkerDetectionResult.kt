package com.nxtend.team35.yubiboard.vision

data class NormalizedPoint(
    val x: Float,
    val y: Float,
)

data class DetectedMarker(
    val id: Int,
    val center: NormalizedPoint,
    val corners: List<NormalizedPoint>,
)

data class MarkerDetectionResult(
    val capturedAtMonotonicMs: Long,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val markers: List<DetectedMarker>,
    val stable: Boolean,
)
