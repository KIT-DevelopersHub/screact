package com.nxtend.team35.yubiboard.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 実UDPソケット（loopback）での待受テスト:
 * offer 受信 → response 返信 → select 受信 → onSelected(自動接続情報) の一連。
 */
class DesktopDiscoveryListenerTest {

    private fun desktopSocket() = DatagramSocket().apply { soTimeout = 5_000 }

    private fun send(socket: DatagramSocket, port: Int, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        socket.send(DatagramPacket(bytes, bytes.size, InetAddress.getLoopbackAddress(), port))
    }

    private fun receive(socket: DatagramSocket): String {
        val packet = DatagramPacket(ByteArray(4096), 4096)
        socket.receive(packet)
        return String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
    }

    @Test
    fun `offer に応答し select で onSelected が呼ばれ待受が止まる`() {
        val latch = CountDownLatch(1)
        var selectedHost: String? = null
        var selectedPort = 0
        var selectedToken: String? = null
        val listener = DesktopDiscoveryListener(
            deviceId = "android-test",
            deviceName = "TestPhone",
            model = "TestModel",
            onSelected = { host, wsPort, token ->
                selectedHost = host
                selectedPort = wsPort
                selectedToken = token
                latch.countDown()
            },
            port = 0, // 空きポートで待受（テスト用）
        )
        listener.start()
        val port = requireNotNull(listener.boundPort)
        val desktop = desktopSocket()
        try {
            send(
                desktop,
                port,
                """{"app":"screact","messageType":"discovery_offer","wsPort":8765,"token":"123456"}""",
            )
            val reply = DiscoveryCodec.parse(receive(desktop))
            assertTrue(reply is DiscoveryResponse)
            reply as DiscoveryResponse
            assertEquals("android-test", reply.deviceId)
            assertEquals("TestPhone", reply.deviceName)

            send(
                desktop,
                port,
                """{"app":"screact","messageType":"discovery_select","deviceId":"android-test",
                    "selected":true,"wsPort":8765,"token":"123456"}""",
            )
            assertTrue("select後にonSelectedが呼ばれる", latch.await(5, TimeUnit.SECONDS))
            assertEquals("127.0.0.1", selectedHost)
            assertEquals(8765, selectedPort)
            assertEquals("123456", selectedToken)
            assertEquals(false, listener.isRunning)
        } finally {
            desktop.close()
            listener.stop()
        }
    }

    @Test
    fun `他端末宛ての select は無視して待受を続ける`() {
        val latch = CountDownLatch(1)
        val listener = DesktopDiscoveryListener(
            deviceId = "android-me",
            deviceName = "Me",
            model = "M",
            onSelected = { _, _, _ -> latch.countDown() },
            port = 0,
        )
        listener.start()
        val port = requireNotNull(listener.boundPort)
        val desktop = desktopSocket()
        try {
            send(
                desktop,
                port,
                """{"app":"screact","messageType":"discovery_select","deviceId":"android-other",
                    "selected":true,"wsPort":8765,"token":"123456"}""",
            )
            // 呼ばれないこと（1秒待って未発火）
            assertEquals(false, latch.await(1, TimeUnit.SECONDS))
            assertTrue(listener.isRunning)
            // その後も offer には応答できる
            send(
                desktop,
                port,
                """{"app":"screact","messageType":"discovery_offer","wsPort":8765,"token":"123456"}""",
            )
            assertTrue(DiscoveryCodec.parse(receive(desktop)) is DiscoveryResponse)
        } finally {
            desktop.close()
            listener.stop()
        }
    }

    @Test
    fun `壊れたデータでは応答せず待受を続ける`() {
        val listener = DesktopDiscoveryListener(
            deviceId = "android-me",
            deviceName = "Me",
            model = "M",
            onSelected = { _, _, _ -> },
            port = 0,
        )
        listener.start()
        val port = requireNotNull(listener.boundPort)
        val desktop = DatagramSocket().apply { soTimeout = 500 }
        try {
            send(desktop, port, "not json at all")
            send(desktop, port, """{"app":"other","messageType":"discovery_offer"}""")
            var replied = false
            try {
                receive(desktop)
                replied = true
            } catch (_: SocketTimeoutException) {
                // 応答なし＝期待どおり
            }
            assertEquals(false, replied)
            assertTrue(listener.isRunning)
        } finally {
            desktop.close()
            listener.stop()
        }
    }
}
