package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class HandDetectionResultTest {
    private val twoHands = HandDetectionResult(
        capturedAtMonotonicMs = 1,
        sourceWidth = 1280,
        sourceHeight = 720,
        hands = listOf(
            TrackedHand(trackId = 12, landmarks = emptyList()),
            TrackedHand(trackId = 7, landmarks = emptyList()),
        ),
    )

    @Test
    fun `single hand mode keeps the primary track only`() {
        assertEquals(listOf(7), twoHands.limitHands(1).hands.map { it.trackId })
    }

    @Test
    fun `dual hand mode keeps the original result`() {
        assertSame(twoHands, twoHands.limitHands(2))
    }

    @Test
    fun `unsupported hand count is rejected`() {
        assertTrue(runCatching { twoHands.limitHands(0) }.isFailure)
        assertTrue(runCatching { twoHands.limitHands(3) }.isFailure)
    }
}
