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
    val stableFrameCount: Int = 0,
    val requiredStableFrames: Int = MarkerStabilityTracker.DEFAULT_REQUIRED_STABLE_FRAMES,
    /** マーカー座標が表示（ミラー補正済み）座標系か。前面カメラも補正するため常に true。 */
    val mirrorCorrected: Boolean = true,
    val cameraFacing: String = "back",
)
