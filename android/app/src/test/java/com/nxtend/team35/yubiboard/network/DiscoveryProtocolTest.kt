package com.nxtend.team35.yubiboard.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class DiscoveryProtocolTest {

    @Test
    fun `probe のエンコードは Desktop と共通の形になる`() {
        val encoded = DiscoveryCodec.encode(DiscoveryProbe(deviceId = "android-abc"))
        val decoded = DiscoveryCodec.parse(encoded)
        assertTrue(decoded is DiscoveryProbe)
        assertEquals("android-abc", (decoded as DiscoveryProbe).deviceId)
        assertTrue(encoded.contains("\"messageType\":\"discovery_probe\""))
    }

    @Test
    fun `実プレフィックスから通常LANとテザリングのbroadcastを計算する`() {
        fun broadcast(ip: String, prefix: Int) =
            ipv4DirectedBroadcast(InetAddress.getByName(ip), prefix)?.hostAddress

        assertEquals("192.168.1.255", broadcast("192.168.1.23", 24))
        assertEquals("172.20.10.15", broadcast("172.20.10.2", 28))
        assertEquals("10.20.31.255", broadcast("10.20.17.3", 20))
        assertNull(ipv4DirectedBroadcast(InetAddress.getByName("10.20.17.3"), 32))
        assertNull(ipv4DirectedBroadcast(InetAddress.getByName("::1"), 64))
        assertNull(ipv4DirectedBroadcast(InetAddress.getByName("10.0.0.1"), 33))
    }

    @Test
    fun `offer をデスクトップ実送信と同じJSONから読める（未知フィールドは無視）`() {
        val text = """
            {"app":"screact","schemaVersion":1,"messageType":"discovery_offer",
             "ip":"192.168.1.5","wsPort":8765,"token":"123456","extra":"ignored"}
        """.trimIndent()
        val message = DiscoveryCodec.parse(text)
        assertTrue(message is DiscoveryOffer)
        message as DiscoveryOffer
        assertEquals("192.168.1.5", message.ip)
        assertEquals(8765, message.wsPort)
        assertEquals("123456", message.token)
    }

    @Test
    fun `response のエンコードに識別フィールドが全て入る`() {
        val encoded = DiscoveryCodec.encode(
            DiscoveryResponse(deviceId = "android-abc", deviceName = "Pixel 7", model = "Pixel 7"),
        )
        val decoded = DiscoveryCodec.parse(encoded)
        assertTrue(decoded is DiscoveryResponse)
        decoded as DiscoveryResponse
        assertEquals("android-abc", decoded.deviceId)
        assertEquals("Pixel 7", decoded.deviceName)
        assertTrue(encoded.contains("\"app\":\"screact\""))
        assertTrue(encoded.contains("\"messageType\":\"discovery_response\""))
    }

    @Test
    fun `select を読める（token と wsPort が自動接続に使える）`() {
        val text = """
            {"app":"screact","schemaVersion":1,"messageType":"discovery_select",
             "deviceId":"android-abc","selected":true,"ip":"192.168.1.5",
             "wsPort":8765,"token":"654321"}
        """.trimIndent()
        val message = DiscoveryCodec.parse(text)
        assertTrue(message is DiscoverySelect)
        message as DiscoverySelect
        assertEquals("android-abc", message.deviceId)
        assertTrue(message.selected)
        assertEquals(8765, message.wsPort)
        assertEquals("654321", message.token)
    }

    @Test
    fun `select_ack のエンコードがデスクトップ側のtryParseと同じ形になる`() {
        val encoded = DiscoveryCodec.encode(DiscoverySelectAck(deviceId = "android-abc"))
        // desktop/lib/net/discovery.dart の DiscoverySelectAck.tryParse が要求する形
        assertTrue(encoded.contains("\"app\":\"screact\""))
        assertTrue(encoded.contains("\"messageType\":\"discovery_select_ack\""))
        assertTrue(encoded.contains("\"deviceId\":\"android-abc\""))
        val decoded = DiscoveryCodec.parse(encoded)
        assertTrue(decoded is DiscoverySelectAck)
        assertEquals("android-abc", (decoded as DiscoverySelectAck).deviceId)
    }

    @Test
    fun `他アプリのJSONや壊れたデータは無視する`() {
        assertNull(DiscoveryCodec.parse("""{"app":"other","messageType":"discovery_offer"}"""))
        assertNull(DiscoveryCodec.parse("not json"))
        assertNull(DiscoveryCodec.parse("[1,2,3]"))
        assertNull(DiscoveryCodec.parse("""{"app":"screact","messageType":"unknown_type"}"""))
        // 必須フィールド欠落（wsPort/token なしの offer）
        assertNull(DiscoveryCodec.parse("""{"app":"screact","messageType":"discovery_offer"}"""))
    }

    @Test
    fun `schema port token が不正な offer は無視する`() {
        listOf(
            """{"app":"screact","schemaVersion":2,"messageType":"discovery_offer","wsPort":8765,"token":"123456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_offer","wsPort":0,"token":"123456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_offer","wsPort":65536,"token":"123456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_offer","wsPort":8765,"token":"12345"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_offer","wsPort":8765,"token":"12A456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_offer","wsPort":8765,"token":"１２３４５６"}""",
        ).forEach { invalid -> assertNull(invalid, DiscoveryCodec.parse(invalid)) }
    }

    @Test
    fun `deviceId は空白を禁止し長さを制限する`() {
        val maximumId = "a".repeat(DISCOVERY_DEVICE_ID_MAX_LENGTH)
        val validResponse =
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_response","deviceId":"$maximumId","deviceName":"Pixel","model":"Pixel"}"""
        assertTrue(DiscoveryCodec.parse(validResponse) is DiscoveryResponse)

        listOf("", "   ", "a".repeat(DISCOVERY_DEVICE_ID_MAX_LENGTH + 1)).forEach { deviceId ->
            val response =
                """{"app":"screact","schemaVersion":1,"messageType":"discovery_response","deviceId":"$deviceId","deviceName":"Pixel","model":"Pixel"}"""
            val ack =
                """{"app":"screact","schemaVersion":1,"messageType":"discovery_select_ack","deviceId":"$deviceId"}"""
            val probe =
                """{"app":"screact","schemaVersion":1,"messageType":"discovery_probe","deviceId":"$deviceId"}"""
            assertNull(DiscoveryCodec.parse(response))
            assertNull(DiscoveryCodec.parse(ack))
            assertNull(DiscoveryCodec.parse(probe))
        }
    }

    @Test
    fun `select にも schema port token deviceId 検証を適用する`() {
        listOf(
            """{"app":"screact","schemaVersion":2,"messageType":"discovery_select","deviceId":"android","wsPort":8765,"token":"123456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_select","deviceId":" ","wsPort":8765,"token":"123456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_select","deviceId":"android","wsPort":-1,"token":"123456"}""",
            """{"app":"screact","schemaVersion":1,"messageType":"discovery_select","deviceId":"android","wsPort":8765,"token":"abcdef"}""",
        ).forEach { invalid -> assertNull(invalid, DiscoveryCodec.parse(invalid)) }
    }
}
