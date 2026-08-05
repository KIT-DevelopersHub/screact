package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertEquals
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
    fun `briefly missing marker keeps valid frame progress`() {
        val tracker = MarkerStabilityTracker()
        repeat(3) { tracker.update(validMarkers()) }
        assertFalse(tracker.update(validMarkers().dropLast(1)))
        assertFalse(tracker.update(validMarkers()))
        assertTrue(tracker.update(validMarkers()))
    }

    @Test
    fun `three invalid frames reset progress`() {
        val tracker = MarkerStabilityTracker()
        repeat(4) { tracker.update(validMarkers()) }

        repeat(3) { assertFalse(tracker.update(validMarkers().dropLast(1))) }

        assertFalse(tracker.update(validMarkers()))
        assertEquals(1, tracker.stableFrameCount)
    }

    @Test
    fun `normal camera jitter is accepted`() {
        val tracker = MarkerStabilityTracker()

        repeat(5) { frame ->
            val offset = if (frame % 2 == 0) 0.012f else -0.002f
            val jittered = validMarkers().map { marker ->
                marker.copy(
                    center = NormalizedPoint(marker.center.x + offset, marker.center.y + offset / 2f),
                )
            }
            if (frame < 4) assertFalse(tracker.update(jittered)) else assertTrue(tracker.update(jittered))
        }
    }

    @Test
    fun `large movement prevents stability`() {
        val tracker = MarkerStabilityTracker()
        repeat(4) { tracker.update(validMarkers()) }
        val moved = validMarkers().map {
            if (it.id == 10) it.copy(center = NormalizedPoint(0.2f, 0.1f)) else it
        }
        assertFalse(tracker.update(moved))
        assertEquals(1, tracker.stableFrameCount)
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

    @Test
    fun `rotated device orientation is accepted`() {
        val tracker = MarkerStabilityTracker(requiredFrames = 1)
        val rotated = validMarkers().map { marker ->
            marker.copy(center = NormalizedPoint(1f - marker.center.y, marker.center.x))
        }

        assertTrue(tracker.update(rotated))
    }

    @Test
    fun `quadrilateral that is too small is rejected`() {
        val tracker = MarkerStabilityTracker(requiredFrames = 1)
        val small = listOf(
            marker(10, 0.45f, 0.45f),
            marker(11, 0.55f, 0.45f),
            marker(12, 0.55f, 0.53f),
            marker(13, 0.45f, 0.53f),
        )

        assertFalse(tracker.update(small))
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
