package com.nxtend.team35.yubiboard.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingPayloadTest {
    @Test
    fun `valid LAN uri parses host port and token`() {
        val payload = PairingPayload.tryParse(
            "screact://pair?v=1&t=123456&host=192.168.1.20&port=8765",
        )
        assertNotNull(payload)
        payload!!
        assertEquals("192.168.1.20", payload.lanHost)
        assertEquals(8765, payload.lanPort)
        assertEquals("123456", payload.pairingToken)
        assertTrue(payload.hasLanDirect)
    }

    @Test
    fun `leading and trailing whitespace is tolerated`() {
        val payload = PairingPayload.tryParse(
            "  screact://pair?v=1&t=654321&host=10.0.0.5&port=8765  ",
        )
        assertNotNull(payload)
        assertEquals("654321", payload!!.pairingToken)
    }

    @Test
    fun `missing token is rejected`() {
        assertNull(
            PairingPayload.tryParse("screact://pair?v=1&host=192.168.1.20&port=8765"),
        )
    }

    @Test
    fun `non six digit token is rejected`() {
        assertNull(
            PairingPayload.tryParse("screact://pair?v=1&t=12345&host=192.168.1.20&port=8765"),
        )
    }

    @Test
    fun `host without valid port is rejected`() {
        assertNull(
            PairingPayload.tryParse("screact://pair?v=1&t=123456&host=192.168.1.20&port=0"),
        )
        assertNull(
            PairingPayload.tryParse("screact://pair?v=1&t=123456&host=192.168.1.20&port=70000"),
        )
        assertNull(
            PairingPayload.tryParse("screact://pair?v=1&t=123456&host=192.168.1.20"),
        )
    }

    @Test
    fun `wrong scheme is rejected`() {
        assertNull(
            PairingPayload.tryParse("https://pair?v=1&t=123456&host=192.168.1.20&port=8765"),
        )
    }

    @Test
    fun `wrong authority is rejected`() {
        assertNull(
            PairingPayload.tryParse("screact://connect?v=1&t=123456&host=192.168.1.20&port=8765"),
        )
    }

    @Test
    fun `unknown or missing version is rejected`() {
        assertNull(
            PairingPayload.tryParse("screact://pair?v=2&t=123456&host=192.168.1.20&port=8765"),
        )
        assertNull(
            PairingPayload.tryParse("screact://pair?t=123456&host=192.168.1.20&port=8765"),
        )
    }

    @Test
    fun `payload with neither lan nor relay is rejected`() {
        assertNull(PairingPayload.tryParse("screact://pair?v=1&t=123456"))
    }

    @Test
    fun `relay requires room`() {
        assertNull(
            PairingPayload.tryParse("screact://pair?v=1&t=123456&relay=wss://r.example/ws"),
        )
        val payload = PairingPayload.tryParse(
            "screact://pair?v=1&t=123456&relay=wss%3A%2F%2Fr.example%2Fws&room=abc123",
        )
        assertNotNull(payload)
        assertTrue(payload!!.hasRelay)
        assertEquals("wss://r.example/ws", payload.relayUrl)
        assertEquals("abc123", payload.relayRoom)
    }

    @Test
    fun `expiry is parsed and evaluated at boundary`() {
        val payload = PairingPayload.tryParse(
            "screact://pair?v=1&t=123456&host=192.168.1.20&port=8765&exp=1000",
        )
        assertNotNull(payload)
        payload!!
        assertEquals(1000L, payload.expiresAt)
        assertFalse(payload.isExpired(999))
        // 境界（等しい）＝失効扱い。
        assertTrue(payload.isExpired(1000))
        assertTrue(payload.isExpired(1001))
    }

    @Test
    fun `no expiry never expires`() {
        val payload = PairingPayload.tryParse(
            "screact://pair?v=1&t=123456&host=192.168.1.20&port=8765",
        )
        assertNotNull(payload)
        assertFalse(payload!!.isExpired(Long.MAX_VALUE))
    }

    @Test
    fun `garbage input is rejected`() {
        assertNull(PairingPayload.tryParse("not a uri at all"))
        assertNull(PairingPayload.tryParse(""))
    }
}
