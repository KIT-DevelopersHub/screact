package com.nxtend.team35.yubiboard.settings

import com.nxtend.team35.yubiboard.network.ConnectionConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrustedConnectionStoreTest {
    @Test
    fun `a recreated app starts automatic resume connection`() {
        val values = FakeValues()
        val protector = PrefixProtector()
        val firstStore = TrustedConnectionStore(values, protector)
        assertTrue(firstStore.save("192.168.1.10", 8080, "resume-secret"))

        val connections = mutableListOf<Pair<ConnectionConfig, Boolean>>()
        val recreatedCoordinator = TrustedConnectionCoordinator(
            TrustedConnectionStore(values, protector),
        ) { config, automatic -> connections += config to automatic }

        assertTrue(recreatedCoordinator.autoConnect())
        assertEquals(1, connections.size)
        assertEquals("resume-secret", connections.single().first.resumeToken)
        assertNull(connections.single().first.pairingToken)
        assertTrue(connections.single().second)
        assertEquals("enc:resume-secret", values.items[TrustedConnectionStore.KEY_RESUME_TOKEN])
    }

    @Test
    fun `forget removes host port and protected token`() {
        val values = FakeValues()
        val store = TrustedConnectionStore(values, PrefixProtector())
        store.save("pc.local", 8080, "resume-secret")

        TrustedConnectionCoordinator(store) { _, _ -> }.forget()

        assertNull(store.load())
        assertFalse(values.items.keys.any { it.startsWith("trusted_") })
    }

    @Test
    fun `unreadable protected token is discarded instead of retried`() {
        val values = FakeValues().apply {
            items[TrustedConnectionStore.KEY_HOST] = "pc.local"
            items[TrustedConnectionStore.KEY_PORT] = 8080
            items[TrustedConnectionStore.KEY_RESUME_TOKEN] = "corrupt"
        }
        val coordinator = TrustedConnectionCoordinator(
            TrustedConnectionStore(values, PrefixProtector()),
        ) { _, _ -> error("must not connect") }

        assertFalse(coordinator.autoConnect())
        assertTrue(values.items.isEmpty())
    }

    private class PrefixProtector : ResumeTokenProtector {
        override fun protect(token: String) = "enc:$token"
        override fun unprotect(protectedToken: String): String {
            require(protectedToken.startsWith("enc:"))
            return protectedToken.removePrefix("enc:")
        }
    }

    private class FakeValues : TrustedConnectionValues {
        val items = mutableMapOf<String, Any>()
        override fun getString(key: String) = items[key] as? String
        override fun getInt(key: String, defaultValue: Int) = items[key] as? Int ?: defaultValue
        override fun put(values: Map<String, Any>) { items.putAll(values) }
        override fun remove(keys: Set<String>) { keys.forEach(items::remove) }
    }
}
