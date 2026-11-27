package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.vision.DetectedMarker
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.LandmarkPoint
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult
import com.nxtend.team35.yubiboard.vision.NormalizedPoint
import com.nxtend.team35.yubiboard.vision.TrackedHand
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** 偽の通信路でセッション処理だけを確かめる。 */
class InputSessionTest {
    private val transport = FakeTransport()
    private val states = CopyOnWriteArrayList<ConnectionSnapshot>()
    private val modes = CopyOnWriteArrayList<CaptureMode>()
    private val session = InputSession(
        transport = transport,
        deviceId = "android-test",
        clientVersion = "0.1.0",
        onStateChanged = { states += it },
        onModeChanged = { modes += it },
    )
    private val config = ConnectionConfig("192.168.0.2", 8765, pairingToken = "123456")

    @After
    fun tearDown() {
        session.close()
    }

    @Test
    fun `hello is sent on open and hand frames wait for hello ack`() {
        session.setCameraFacing(usingFrontCamera = true)
        session.connect(config)
        val connection = transport.single()
        assertEquals(ConnectionStatus.CONNECTING, states.last().status)

        connection.open()
        assertEquals(ConnectionStatus.AWAITING_ACK, states.last().status)
        val hello = connection.sent.single()
        assertTrue(hello.contains("\"messageType\":\"hello\""))
        assertTrue(hello.contains("\"pairingToken\":\"123456\""))
        assertTrue(hello.contains("\"cameraFacing\":\"front\""))

        session.submitHand(sampleHand())
        Thread.sleep(150)
        assertTrue(connection.sent.none { it.contains("hand_frame") })

        connection.receive(helloAck("s-fake"))
        assertEquals(ConnectionSnapshot(ConnectionStatus.CONNECTED, "s-fake"), states.last())
        assertEquals(listOf(CaptureMode.TRACKING), modes)
        val frame = waitForMessage(connection, "hand_frame")
        assertTrue(frame.contains("\"sessionId\":\"s-fake\""))
        assertTrue(frame.contains("\"frameId\":1"))
    }

    @Test
    fun `only the latest hand is sent when several are submitted before a flush`() {
        val connection = connectAndAck()
        connection.queued.set(MAX_QUEUE_BYTES + 1)
        session.submitHand(sampleHand(capturedAt = 1))
        session.submitHand(sampleHand(capturedAt = 2))
        Thread.sleep(150)
        assertTrue(connection.sent.none { it.contains("hand_frame") })

        connection.queued.set(0)
        val frame = waitForMessage(connection, "hand_frame")
        assertTrue(frame.contains("\"capturedAtMonotonicMs\":2"))
        Thread.sleep(150)
        assertEquals(1, connection.sent.count { it.contains("hand_frame") })
    }

    @Test
    fun `hand frame that failed to send is retried`() {
        val connection = connectAndAck()
        connection.acceptSends.set(false)
        session.submitHand(sampleHand())
        Thread.sleep(150)
        assertTrue(connection.sent.none { it.contains("hand_frame") })

        connection.acceptSends.set(true)
        waitForMessage(connection, "hand_frame")
    }

    @Test
    fun `stable calibration is sent after hello ack`() {
        val connection = connectAndAck(calibrationRequired = true)
        assertEquals(listOf(CaptureMode.CALIBRATION), modes)
        session.submitCalibration(sampleCalibration())
        val markers = waitForMessage(connection, "calibration_markers")
        assertTrue(markers.contains("\"sessionId\":\"s-fake\""))
    }

    @Test
    fun `messages from a replaced connection are ignored`() {
        session.connect(config)
        val first = transport.single()
        session.connect(config)
        assertTrue(first.cancelled.get())
        val second = transport.connections.last()

        first.open()
        assertTrue(first.sent.isEmpty())
        first.receive(helloAck("stale"))
        assertTrue(states.none { it.status == ConnectionStatus.CONNECTED })

        second.open()
        second.receive(helloAck("current"))
        assertEquals("current", states.last().sessionId)
    }

    @Test
    fun `closed connection schedules a reconnect through the transport`() {
        val connection = connectAndAck()
        connection.closeFromRemote("接続が閉じられました: 1006 ")

        val reconnecting = states.last()
        assertEquals(ConnectionStatus.RECONNECTING, reconnecting.status)
        assertEquals(ConnectionErrorCode.UNREACHABLE, reconnecting.errorCode)
        assertEquals(1, reconnecting.retryInSeconds)

        waitUntil(3_000) { transport.connections.size == 2 }
        val next = transport.connections.last()
        next.open()
        assertTrue(next.sent.single().contains("\"messageType\":\"hello\""))
    }

    @Test
    fun `retryable hello error cancels and reports the error code on reconnect`() {
        session.connect(config)
        val connection = transport.single()
        connection.open()
        connection.receive(
            """{"schemaVersion":1,"messageType":"hello_error","code":"server_busy","retryable":true}""",
        )
        assertTrue(connection.cancelled.get())
        connection.closeFromRemote("canceled")

        assertEquals(ConnectionStatus.RECONNECTING, states.last().status)
        assertEquals(ConnectionErrorCode.SERVER_BUSY, states.last().errorCode)
    }

    @Test
    fun `remote disconnect control closes the connection without reconnecting`() {
        val connection = connectAndAck()
        connection.receive(
            """{"schemaVersion":1,"messageType":"control_message","sessionId":"s-fake","command":"disconnect"}""",
        )
        assertEquals(1000 to "user disconnect", connection.closedWith)
        assertEquals(ConnectionStatus.DISCONNECTED, states.last().status)

        connection.closeFromRemote("接続が閉じられました: 1000 user disconnect")
        Thread.sleep(1_300)
        assertEquals(1, transport.connections.size)
    }

    @Test
    fun `close shuts down the transport`() {
        connectAndAck()
        session.close()
        assertTrue(transport.shutDown.get())
        assertNull(states.last().sessionId)
        assertEquals(ConnectionStatus.DISCONNECTED, states.last().status)
        assertFalse(transport.connections.single().cancelled.get())
    }

    private fun connectAndAck(calibrationRequired: Boolean = false): FakeConnection {
        session.connect(config)
        val connection = transport.single()
        connection.open()
        connection.receive(helloAck("s-fake", calibrationRequired))
        return connection
    }

    private fun helloAck(sessionId: String, calibrationRequired: Boolean = false) =
        """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"$sessionId","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":$calibrationRequired}"""

    private fun waitForMessage(connection: FakeConnection, messageType: String): String {
        waitUntil(2_000) { connection.sent.any { it.contains("\"messageType\":\"$messageType\"") } }
        return connection.sent.first { it.contains("\"messageType\":\"$messageType\"") }
    }

    private fun waitUntil(timeoutMs: Long, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!condition()) {
            assertTrue("条件を満たさないまま時間切れ", System.currentTimeMillis() < deadline)
            Thread.sleep(10)
        }
    }

    private class FakeTransport : InputTransport {
        val connections = CopyOnWriteArrayList<FakeConnection>()
        val shutDown = AtomicBoolean(false)

        override fun open(config: ConnectionConfig, listener: InputTransportListener): TransportConnection =
            FakeConnection(listener).also { connections += it }

        override fun shutdown() {
            shutDown.set(true)
        }

        fun single(): FakeConnection = connections.single()
    }

    private class FakeConnection(
        private val listener: InputTransportListener,
    ) : TransportConnection {
        val sent = CopyOnWriteArrayList<String>()
        val queued = AtomicLong(0)
        val acceptSends = AtomicBoolean(true)
        val cancelled = AtomicBoolean(false)

        @Volatile
        var closedWith: Pair<Int, String>? = null

        override val kind: String = "fake"

        override fun send(text: String): Boolean {
            if (!acceptSends.get()) return false
            sent += text
            return true
        }

        override fun queuedBytes(): Long = queued.get()

        override fun close(code: Int, reason: String) {
            closedWith = code to reason
        }

        override fun cancel() {
            cancelled.set(true)
        }

        fun open() = listener.onOpened(this)

        fun receive(text: String) = listener.onText(this, text)

        fun closeFromRemote(detail: String) = listener.onClosed(this, detail)
    }

    private fun sampleHand(capturedAt: Long = 100) = HandDetectionResult(
        capturedAtMonotonicMs = capturedAt,
        sourceWidth = 640,
        sourceHeight = 480,
        hands = listOf(
            TrackedHand(
                trackId = 1,
                landmarks = List(21) { LandmarkPoint(0.5f, 0.5f, 0f) },
                handedness = "RIGHT",
                handednessScore = 0.9f,
            ),
        ),
    )

    private fun sampleCalibration(): MarkerDetectionResult {
        fun marker(id: Int, x: Float, y: Float) = DetectedMarker(
            id = id,
            center = NormalizedPoint(x, y),
            corners = listOf(
                NormalizedPoint(x - 0.02f, y - 0.02f),
                NormalizedPoint(x + 0.02f, y - 0.02f),
                NormalizedPoint(x + 0.02f, y + 0.02f),
                NormalizedPoint(x - 0.02f, y + 0.02f),
            ),
        )
        return MarkerDetectionResult(
            capturedAtMonotonicMs = 200,
            sourceWidth = 1280,
            sourceHeight = 720,
            markers = listOf(
                marker(10, 0.1f, 0.1f),
                marker(11, 0.9f, 0.1f),
                marker(12, 0.9f, 0.9f),
                marker(13, 0.1f, 0.9f),
            ),
            stable = true,
        )
    }

    private companion object {
        const val MAX_QUEUE_BYTES = 256L * 1024L
    }
}
