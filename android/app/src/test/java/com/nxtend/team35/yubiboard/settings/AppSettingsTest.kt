package com.nxtend.team35.yubiboard.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppSettingsTest {
    @Test
    fun `single hand is the default mode`() {
        assertEquals(1, AppSettings().maxHands)
    }

    @Test
    fun `one or two hands are accepted`() {
        assertNull(AppSettings(maxHands = 1).validate())
        assertNull(AppSettings(maxHands = 2).validate())
    }

    @Test
    fun `unsupported hand count is rejected`() {
        assertEquals("操作する手の数は1または2です", AppSettings(maxHands = 0).validate())
        assertEquals("操作する手の数は1または2です", AppSettings(maxHands = 3).validate())
    }

    @Test
    fun `inference stride defaults to every frame`() {
        assertEquals(1, AppSettings().inferenceFrameStride)
        assertNull(AppSettings().validate())
    }

    @Test
    fun `inference stride within 1 to 4 is accepted`() {
        assertNull(AppSettings(inferenceFrameStride = 1).validate())
        assertNull(AppSettings(inferenceFrameStride = 2).validate())
        assertNull(AppSettings(inferenceFrameStride = 4).validate())
    }

    @Test
    fun `out of range inference stride is rejected`() {
        assertEquals("推論の間引きは1〜4です", AppSettings(inferenceFrameStride = 0).validate())
        assertEquals("推論の間引きは1〜4です", AppSettings(inferenceFrameStride = 5).validate())
    }
}
