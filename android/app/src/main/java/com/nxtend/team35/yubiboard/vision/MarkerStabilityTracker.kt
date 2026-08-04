package com.nxtend.team35.yubiboard.vision

import kotlin.math.abs
import kotlin.math.hypot

class MarkerStabilityTracker(
    private val requiredFrames: Int = DEFAULT_REQUIRED_FRAMES,
    private val maxCenterMovement: Float = DEFAULT_MAX_CENTER_MOVEMENT,
) {
    private val history = ArrayDeque<Map<Int, NormalizedPoint>>()

    fun update(markers: List<DetectedMarker>): Boolean {
        if (!hasExpectedLayout(markers)) {
            history.clear()
            return false
        }
        history.addLast(markers.associate { it.id to it.center })
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

    fun reset() = history.clear()

    private fun hasExpectedLayout(markers: List<DetectedMarker>): Boolean {
        if (markers.map { it.id }.toSet() != EXPECTED_IDS || markers.size != EXPECTED_IDS.size) {
            return false
        }
        val centers = markers.associate { it.id to it.center }
        val topLeft = centers.getValue(ID_TOP_LEFT)
        val topRight = centers.getValue(ID_TOP_RIGHT)
        val bottomRight = centers.getValue(ID_BOTTOM_RIGHT)
        val bottomLeft = centers.getValue(ID_BOTTOM_LEFT)
        val area = polygonArea(listOf(topLeft, topRight, bottomRight, bottomLeft))
        return topLeft.x < topRight.x &&
            bottomLeft.x < bottomRight.x &&
            topLeft.y < bottomLeft.y &&
            topRight.y < bottomRight.y &&
            area >= MIN_QUADRILATERAL_AREA
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

        private const val DEFAULT_REQUIRED_FRAMES = 5
        private const val DEFAULT_MAX_CENTER_MOVEMENT = 0.01f
        private const val MIN_QUADRILATERAL_AREA = 0.05f
    }
}
