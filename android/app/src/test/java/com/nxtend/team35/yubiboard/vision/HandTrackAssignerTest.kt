package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HandTrackAssignerTest {
    @Test
    fun `keeps ids when MediaPipe order changes`() {
        val assigner = HandTrackAssigner()
        val first = assigner.assign(listOf(handAt(0.2f), handAt(0.8f)), 1_000)
        val second = assigner.assign(listOf(handAt(0.78f), handAt(0.22f)), 1_050)

        assertEquals(first.map { it.trackId }, second.map { it.trackId })
        assertEquals(0.22f, second[0].landmarks[0].x)
        assertEquals(0.78f, second[1].landmarks[0].x)
    }

    @Test
    fun `restores a briefly missing hand but removes it from current frame`() {
        val assigner = HandTrackAssigner()
        val original = assigner.assign(listOf(handAt(0.3f), handAt(0.7f)), 1_000)
        val visible = assigner.assign(listOf(handAt(0.31f)), 1_100)
        val restored = assigner.assign(listOf(handAt(0.32f), handAt(0.69f)), 1_250)

        assertEquals(listOf(original[0].trackId), visible.map { it.trackId })
        assertEquals(original.map { it.trackId }, restored.map { it.trackId })
    }

    @Test
    fun `allocates a new id after retention expires`() {
        val assigner = HandTrackAssigner()
        val original = assigner.assign(listOf(handAt(0.4f)), 1_000).single().trackId
        assertTrue(assigner.assign(emptyList(), 1_301).isEmpty())
        val replacement = assigner.assign(listOf(handAt(0.4f)), 1_302).single().trackId

        assertNotEquals(original, replacement)
    }

    @Test
    fun `distance gate prevents an implausible id jump`() {
        val assigner = HandTrackAssigner()
        val original = assigner.assign(listOf(handAt(0.1f)), 1_000).single().trackId
        val far = assigner.assign(listOf(handAt(0.9f)), 1_010).single().trackId

        assertNotEquals(original, far)
    }

    @Test
    fun `drops malformed and non finite candidates`() {
        val assigner = HandTrackAssigner()
        val short = HandCandidate(List(20) { LandmarkPoint(0.5f, 0.5f, 0f) })
        val infinite = HandCandidate(List(21) { LandmarkPoint(Float.POSITIVE_INFINITY, 0.5f, 0f) })

        assertTrue(assigner.assign(listOf(short, infinite), 1_000).isEmpty())
    }

    private fun handAt(x: Float) = HandCandidate(
        landmarks = List(21) { LandmarkPoint(x, 0.5f, -0.01f) },
    )
}
