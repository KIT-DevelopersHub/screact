package com.nxtend.team35.yubiboard.vision

import kotlin.math.abs
import kotlin.math.hypot

class MarkerStabilityTracker(
    private val requiredFrames: Int = DEFAULT_REQUIRED_STABLE_FRAMES,
    private val maxCenterMovement: Float = DEFAULT_MAX_CENTER_MOVEMENT,
    private val toleratedInvalidFrames: Int = DEFAULT_TOLERATED_INVALID_FRAMES,
) {
    private val history = ArrayDeque<Map<Int, NormalizedPoint>>()
    private var consecutiveInvalidFrames = 0
    val stableFrameCount: Int get() = history.size

    fun update(markers: List<DetectedMarker>): Boolean {
        if (!hasExpectedLayout(markers)) {
            consecutiveInvalidFrames += 1
            if (consecutiveInvalidFrames > toleratedInvalidFrames) history.clear()
            return false
        }

        consecutiveInvalidFrames = 0
        val centers = markers.associate { it.id to it.center }
        if (history.isNotEmpty() && !centersAreStable(history.first(), centers)) {
            history.clear()
        }
        history.addLast(centers)
        while (history.size > requiredFrames) history.removeFirst()
        if (history.size < requiredFrames) return false

        return EXPECTED_IDS.all { id ->
            val points = history.mapNotNull { it[id] }
            points.size == requiredFrames && points.all { point ->
                hypot(
                    (point.x - points.first().x).toDouble(),
                    (point.y - points.first().y).toDouble(),
                ) <= maxCenterMovement
            }
        }
    }

    fun reset() {
        history.clear()
        consecutiveInvalidFrames = 0
    }

    private fun centersAreStable(
        reference: Map<Int, NormalizedPoint>,
        candidate: Map<Int, NormalizedPoint>,
    ): Boolean = EXPECTED_IDS.all { id ->
        val first = reference.getValue(id)
        val current = candidate.getValue(id)
        hypot(
            (current.x - first.x).toDouble(),
            (current.y - first.y).toDouble(),
        ) <= maxCenterMovement
    }

    private fun hasExpectedLayout(markers: List<DetectedMarker>): Boolean {
        if (markers.map { it.id }.toSet() != EXPECTED_IDS || markers.size != EXPECTED_IDS.size) {
            return false
        }
        val centers = markers.associate { it.id to it.center }
        val ordered = listOf(
            centers.getValue(ID_TOP_LEFT),
            centers.getValue(ID_TOP_RIGHT),
            centers.getValue(ID_BOTTOM_RIGHT),
            centers.getValue(ID_BOTTOM_LEFT),
        )
        val turns = ordered.indices.map { index ->
            val first = ordered[index]
            val second = ordered[(index + 1) % ordered.size]
            val third = ordered[(index + 2) % ordered.size]
            (second.x - first.x) * (third.y - second.y) -
                (second.y - first.y) * (third.x - second.x)
        }
        return polygonArea(ordered) >= MIN_QUADRILATERAL_AREA &&
            turns.all { it > MIN_TURN_CROSS_PRODUCT }
    }

    private fun polygonArea(points: List<NormalizedPoint>): Float {
        var twiceArea = 0f
        points.indices.forEach { index ->
            val current = points[index]
            val next = points[(index + 1) % points.size]
            twiceArea += current.x * next.y - next.x * current.y
        }
        return abs(twiceArea) / 2f
    }

    companion object {
        const val ID_TOP_LEFT = 10
        const val ID_TOP_RIGHT = 11
        const val ID_BOTTOM_RIGHT = 12
        const val ID_BOTTOM_LEFT = 13
        val EXPECTED_IDS = setOf(ID_TOP_LEFT, ID_TOP_RIGHT, ID_BOTTOM_RIGHT, ID_BOTTOM_LEFT)

        const val DEFAULT_REQUIRED_STABLE_FRAMES = 5
        const val DEFAULT_TOLERATED_INVALID_FRAMES = 2
        private const val DEFAULT_MAX_CENTER_MOVEMENT = 0.02f
        private const val MIN_QUADRILATERAL_AREA = 0.01f
        private const val MIN_TURN_CROSS_PRODUCT = 0.00001f
    }
}
