package com.nxtend.team35.yubiboard.vision

data class LandmarkPoint(
    val x: Float,
    val y: Float,
    val z: Float,
)

data class HandCandidate(
    val landmarks: List<LandmarkPoint>,
    val handedness: String? = null,
    val handednessScore: Float? = null,
)

data class TrackedHand(
    val trackId: Int,
    val landmarks: List<LandmarkPoint>,
    val handedness: String? = null,
    val handednessScore: Float? = null,
)

data class HandDetectionResult(
    val capturedAtMonotonicMs: Long,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val hands: List<TrackedHand> = emptyList(),
    val trackingState: TrackingState = if (hands.isNotEmpty()) {
        TrackingState.TRACKING
    } else {
        TrackingState.UNDETECTED
    },
    val inferenceTimeMs: Long = 0,
    val framesPerSecond: Float = 0f,
    /** ランドマークが表示（ミラー補正済み）座標系か。前面カメラも補正するため常に true。 */
    val mirrorCorrected: Boolean = true,
) {
    val detected: Boolean get() = hands.isNotEmpty()
    val primaryHand: TrackedHand? get() = hands.minByOrNull(TrackedHand::trackId)
    val landmarks: List<LandmarkPoint> get() = primaryHand?.landmarks.orEmpty()
    val handedness: String? get() = primaryHand?.handedness
    val handednessScore: Float? get() = primaryHand?.handednessScore
}

fun HandDetectionResult.limitHands(maxHands: Int): HandDetectionResult {
    require(maxHands in 1..HandTrackAssigner.MAX_HANDS)
    if (hands.size <= maxHands) return this
    return copy(hands = hands.sortedBy { it.trackId }.take(maxHands))
}
