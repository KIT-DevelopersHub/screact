package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkerStabilityTrackerTest {
    @Test
    fun `becomes stable after five valid frames`() {
        val tracker = MarkerStabilityTracker()

        repeat(4) { assertFalse(tracker.update(validMarkers())) }
        assertTrue(tracker.update(validMarkers()))
    }

    @Test
    fun `missing marker resets consecutive history`() {
        val tracker = MarkerStabilityTracker()
        repeat(4) { tracker.update(validMarkers()) }
        assertFalse(tracker.update(validMarkers().dropLast(1)))
        assertFalse(tracker.update(validMarkers()))
    }

    @Test
    fun `large movement prevents stability`() {
        val tracker = MarkerStabilityTracker()
        repeat(4) { tracker.update(validMarkers()) }
        val moved = validMarkers().map {
            if (it.id == 10) it.copy(center = NormalizedPoint(0.2f, 0.1f)) else it
        }
        assertFalse(tracker.update(moved))
    }

    @Test
    fun `incorrect id placement is rejected`() {
        val tracker = MarkerStabilityTracker(requiredFrames = 1)
        val swapped = validMarkers().map {
            when (it.id) {
                10 -> it.copy(id = 11)
                11 -> it.copy(id = 10)
                else -> it
            }
        }
        assertFalse(tracker.update(swapped))
    }

    private fun validMarkers(): List<DetectedMarker> = listOf(
        marker(10, 0.1f, 0.1f),
        marker(11, 0.9f, 0.1f),
        marker(12, 0.9f, 0.9f),
        marker(13, 0.1f, 0.9f),
    )

    private fun marker(id: Int, x: Float, y: Float) = DetectedMarker(
        id = id,
        center = NormalizedPoint(x, y),
        corners = listOf(
            NormalizedPoint(x - 0.02f, y - 0.02f),
            NormalizedPoint(x + 0.02f, y - 0.02f),
            NormalizedPoint(x + 0.02f, y + 0.02f),
            NormalizedPoint(x - 0.02f, y + 0.02f),
        ),
    )
}
