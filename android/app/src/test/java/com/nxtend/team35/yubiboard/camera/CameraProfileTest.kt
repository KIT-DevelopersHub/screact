package com.nxtend.team35.yubiboard.camera

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraProfileTest {
    @Test
    fun `production profiles are ordered from 720p to compatibility`() {
        assertEquals(
            listOf(CameraProfile.HD_720, CameraProfile.QHD_540, CameraProfile.VGA_480),
            CameraProfile.productionOrder,
        )
    }
}
