package com.nxtend.team35.yubiboard.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryProtocolTest {

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
}
