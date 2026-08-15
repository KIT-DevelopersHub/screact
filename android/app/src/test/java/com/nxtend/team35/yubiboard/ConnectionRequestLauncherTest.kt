package com.nxtend.team35.yubiboard

import com.nxtend.team35.yubiboard.network.ConnectionConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionRequestLauncherTest {
    @Test
    fun `manual and discovery paths preserve their automatic flag`() {
        val launched = mutableListOf<Pair<ConnectionConfig, Boolean>>()
        val launcher = ConnectionRequestLauncher { config, automatic ->
            launched += config to automatic
        }

        assertNull(launcher.connect(" 192.168.1.10 ", "8765", " 123456 ", automatic = false))
        assertNull(launcher.connect("192.168.1.11", "8765", "654321", automatic = true))

        assertEquals(2, launched.size)
        assertEquals("192.168.1.10", launched[0].first.host)
        assertEquals(false, launched[0].second)
        assertEquals("192.168.1.11", launched[1].first.host)
        assertEquals(true, launched[1].second)
    }

    @Test
    fun `invalid discovery connection is rejected before websocket launch`() {
        var launchCount = 0
        val launcher = ConnectionRequestLauncher { _, _ -> launchCount++ }

        assertNotNull(launcher.connect("192.168.1.10", "0", "123456", automatic = true))
        assertNotNull(launcher.connect("192.168.1.10", "8765", "invalid", automatic = true))
        assertEquals(0, launchCount)
    }
}
