package com.nxtend.team35.yubiboard.vision

data class LandmarkPoint(
    val x: Float,
    val y: Float,
    val z: Float,
)

data class HandDetectionResult(
    val capturedAtMonotonicMs: Long,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val detected: Boolean,
    val landmarks: List<LandmarkPoint> = emptyList(),
    val handedness: String? = null,
    val handednessScore: Float? = null,
    val inferenceTimeMs: Long = 0,
    val framesPerSecond: Float = 0f,
)
