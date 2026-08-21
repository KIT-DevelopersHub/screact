package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertEquals
import org.junit.Test

class MirrorCorrectionTest {
    @Test
    fun `hand landmarks mirror only x and preserve metadata`() {
        val candidate = HandCandidate(
            landmarks = listOf(LandmarkPoint(0.2f, 0.3f, -0.1f)),
            handedness = "RIGHT",
            handednessScore = 0.9f,
        )

        val mirrored = candidate.mirrorHorizontally()

        assertEquals(0.8f, mirrored.landmarks.single().x, 0.0001f)
        assertEquals(0.3f, mirrored.landmarks.single().y, 0.0001f)
        assertEquals(-0.1f, mirrored.landmarks.single().z, 0.0001f)
        assertEquals("RIGHT", mirrored.handedness)
        assertEquals(0.9f, mirrored.handednessScore!!, 0.0001f)
    }

    @Test
    fun `marker mirrors center and every corner while preserving id`() {
        val marker = DetectedMarker(
            id = 10,
            center = NormalizedPoint(0.25f, 0.4f),
            corners = listOf(
                NormalizedPoint(0.2f, 0.3f),
                NormalizedPoint(0.3f, 0.3f),
                NormalizedPoint(0.3f, 0.5f),
                NormalizedPoint(0.2f, 0.5f),
            ),
        )

        val mirrored = marker.mirrorHorizontally()

        assertEquals(10, mirrored.id)
        assertEquals(0.75f, mirrored.center.x, 0.0001f)
        assertEquals(0.4f, mirrored.center.y, 0.0001f)
        assertEquals(listOf(0.8f, 0.7f, 0.7f, 0.8f), mirrored.corners.map { it.x })
        assertEquals(listOf(0.3f, 0.3f, 0.5f, 0.5f), mirrored.corners.map { it.y })
    }
}
