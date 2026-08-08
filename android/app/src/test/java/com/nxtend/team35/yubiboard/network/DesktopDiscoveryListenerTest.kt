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
 * 実UDPソケット（loopback）での待受テスト。接続の向きを反転したため、
 * offer 受信で（PC の ip/wsPort/token を使って）自分から接続しに行く。
 * PC→Android の生UDPユニキャスト(select)は接続経路から外れている。
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
    fun `offer 受信で response返信と onConnect が行われる`() {
        val latch = CountDownLatch(1)
        var connectHost: String? = null
        var connectPort = 0
        var connectToken: String? = null
        val listener = DesktopDiscoveryListener(
            deviceId = "android-test",
            deviceName = "TestPhone",
            model = "TestModel",
            onConnect = { host, wsPort, token ->
                connectHost = host
                connectPort = wsPort
                connectToken = token
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
            // offer に対して response が返る（PCのUI/ログ表示用）
            val reply = DiscoveryCodec.parse(receive(desktop))
            assertTrue(reply is DiscoveryResponse)
            reply as DiscoveryResponse
            assertEquals("android-test", reply.deviceId)
            assertEquals("TestPhone", reply.deviceName)
            // offer の ip/wsPort/token で onConnect が呼ばれる（host=送信元=loopback）
            assertTrue("offerでonConnectが呼ばれる", latch.await(5, TimeUnit.SECONDS))
            assertEquals("127.0.0.1", connectHost)
            assertEquals(8765, connectPort)
            assertEquals("123456", connectToken)
        } finally {
            desktop.close()
            listener.stop()
        }
    }

    @Test
    fun `複数の offer でも onConnect は1回だけ・以後は応答しない`() {
        var connectCount = 0
        val latch = CountDownLatch(1)
        val listener = DesktopDiscoveryListener(
            deviceId = "android-test",
            deviceName = "TestPhone",
            model = "TestModel",
            onConnect = { _, _, _ ->
                connectCount++
                latch.countDown()
            },
            port = 0,
        )
        listener.start()
        val port = requireNotNull(listener.boundPort)
        val desktop = desktopSocket()
        try {
            val offer =
                """{"app":"screact","messageType":"discovery_offer","wsPort":8765,"token":"123456"}"""
            // 1回目: response が返り onConnect が発火する
            send(desktop, port, offer)
            assertTrue(DiscoveryCodec.parse(receive(desktop)) is DiscoveryResponse)
            assertTrue(latch.await(5, TimeUnit.SECONDS))
            // 2回目以降の offer には応答しない（接続開始済み）
            send(desktop, port, offer)
            desktop.soTimeout = 500
            var replied = false
            try {
                receive(desktop)
                replied = true
            } catch (_: SocketTimeoutException) {
                // 応答なし＝期待どおり
            }
            assertEquals(false, replied)
            Thread.sleep(200)
            assertEquals(1, connectCount)
        } finally {
            desktop.close()
            listener.stop()
        }
    }

    @Test
    fun `後方互換 自分宛て select には ACK を返す（接続はトリガしない）`() {
        var connectCount = 0
        val listener = DesktopDiscoveryListener(
            deviceId = "android-me",
            deviceName = "Me",
            model = "M",
            onConnect = { _, _, _ -> connectCount++ },
            port = 0,
        )
        listener.start()
        val port = requireNotNull(listener.boundPort)
        val desktop = desktopSocket()
        try {
            send(
                desktop,
                port,
                """{"app":"screact","messageType":"discovery_select","deviceId":"android-me",
                    "selected":true,"wsPort":8765,"token":"123456"}""",
            )
            // ACK は返るが、select では onConnect は呼ばれない
            val ack = DiscoveryCodec.parse(receive(desktop))
            assertTrue(ack is DiscoverySelectAck)
            assertEquals("android-me", (ack as DiscoverySelectAck).deviceId)
            Thread.sleep(200)
            assertEquals(0, connectCount)
            assertTrue(listener.isRunning)
        } finally {
            desktop.close()
            listener.stop()
        }
    }

    @Test
    fun `壊れたデータでは応答も接続もせず待受を続ける`() {
        var connectCount = 0
        val listener = DesktopDiscoveryListener(
            deviceId = "android-me",
            deviceName = "Me",
            model = "M",
            onConnect = { _, _, _ -> connectCount++ },
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
            assertEquals(0, connectCount)
            assertTrue(listener.isRunning)
        } finally {
            desktop.close()
            listener.stop()
        }
    }
}
