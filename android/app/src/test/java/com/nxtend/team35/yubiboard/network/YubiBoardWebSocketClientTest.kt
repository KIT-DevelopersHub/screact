package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.protocol.ProtocolCodec
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.LandmarkPoint
import com.nxtend.team35.yubiboard.vision.TrackedHand
import com.nxtend.team35.yubiboard.vision.DetectedMarker
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult
import com.nxtend.team35.yubiboard.vision.NormalizedPoint
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class YubiBoardWebSocketClientTest {
    @Test
    fun `camera facing is sent in hello and lens switch invalidates calibration`() {
        val server = MockWebServer()
        val connected = CountDownLatch(1)
        val changed = CountDownLatch(1)
        val hello = AtomicReference<String>()
        val cameraChanged = AtomicReference<String>()
        val serverSocket = AtomicReference<WebSocket>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSocket.set(webSocket)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        when {
                            text.contains("\"messageType\":\"hello\"") -> {
                                hello.set(text)
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"camera-session","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":false}""",
                                )
                            }
                            text.contains("\"messageType\":\"camera_changed\"") -> {
                                cameraChanged.set(text)
                                changed.countDown()
                            }
                        }
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {
                if (it.status == ConnectionStatus.CONNECTED) connected.countDown()
            },
            onModeChanged = {},
        )
        try {
            client.setCameraFacing(usingFrontCamera = true)
            val url = server.url("/")
            client.connect(ConnectionConfig(url.host, url.port, pairingToken = "123456"))
            assertTrue(connected.await(2, TimeUnit.SECONDS))
            assertTrue(hello.get().contains("\"cameraFacing\":\"front\""))

            client.notifyCameraChanged(usingFrontCamera = false)
            assertTrue(changed.await(2, TimeUnit.SECONDS))
            assertTrue(cameraChanged.get().contains("\"sessionId\":\"camera-session\""))
            assertTrue(cameraChanged.get().contains("\"cameraFacing\":\"back\""))
        } finally {
            client.disconnect()
            serverSocket.get()?.close(1000, "test complete")
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `hello ack delivers resume token for secure persistence`() {
        val server = MockWebServer()
        val issued = CountDownLatch(1)
        val received = AtomicReference<Pair<ConnectionConfig, String>>()
        val serverSocket = AtomicReference<WebSocket>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSocket.set(webSocket)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        if (text.contains("\"messageType\":\"hello\"")) {
                            webSocket.send(
                                """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s-issued","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":false,"resumeToken":"issued-resume"}""",
                            )
                        }
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {},
            onModeChanged = {},
            onTrustedConnectionIssued = { config, token ->
                received.set(config to token)
                issued.countDown()
            },
        )
        try {
            val url = server.url("/")
            client.connect(ConnectionConfig(url.host, url.port, pairingToken = "123456"))

            assertTrue(issued.await(2, TimeUnit.SECONDS))
            assertEquals("issued-resume", received.get().second)
            assertEquals("123456", received.get().first.pairingToken)
        } finally {
            client.disconnect()
            serverSocket.get()?.close(1000, "test complete")
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `invalid resume token stops automatic retry and returns to initial connection`() {
        val server = MockWebServer()
        val invalidated = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val hello = AtomicReference<String>()
        val states = CopyOnWriteArrayList<ConnectionSnapshot>()
        val serverSocket = AtomicReference<WebSocket>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSocket.set(webSocket)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        if (text.contains("\"messageType\":\"hello\"")) {
                            hello.set(text)
                            webSocket.send(
                                """{"schemaVersion":1,"messageType":"hello_error","code":"resume_token_invalid","retryable":false}""",
                            )
                        }
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {
                states += it
                if (it.status == ConnectionStatus.DISCONNECTED &&
                    it.errorCode == ConnectionErrorCode.RESUME_TOKEN_INVALID
                ) {
                    disconnected.countDown()
                }
            },
            onModeChanged = {},
            onTrustedConnectionInvalid = { invalidated.countDown() },
        )
        try {
            val url = server.url("/")
            client.connect(
                ConnectionConfig(url.host, url.port, resumeToken = "saved-resume"),
                automatic = true,
            )

            assertTrue(invalidated.await(2, TimeUnit.SECONDS))
            assertTrue(disconnected.await(2, TimeUnit.SECONDS))
            assertTrue(hello.get().contains("\"resumeToken\":\"saved-resume\""))
            assertTrue(!hello.get().contains("pairingToken"))
            assertTrue(states.none { it.status == ConnectionStatus.RECONNECTING })
        } finally {
            client.disconnect()
            serverSocket.get()?.close(1000, "test complete")
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `hand frame is sent only after hello acknowledgement`() {
        val server = MockWebServer()
        val helloReceived = CountDownLatch(1)
        val handReceived = CountDownLatch(1)
        val serverClosed = CountDownLatch(1)
        val serverSocket = AtomicReference<WebSocket>()
        val messages = mutableListOf<String>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSocket.set(webSocket)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        synchronized(messages) { messages += text }
                        when {
                            text.contains("\"messageType\":\"hello\"") -> {
                                helloReceived.countDown()
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s-test","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":false}""",
                                )
                            }

                            text.contains("\"messageType\":\"hand_frame\"") -> handReceived.countDown()
                        }
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        serverClosed.countDown()
                    }
                },
            ),
        )
        server.start()
        val modes = mutableListOf<CaptureMode>()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {},
            onModeChanged = { modes += it },
        )
        try {
            client.submitHand(sampleHand())
            val url = server.url("/")
            client.connect(ConnectionConfig(url.host, url.port, "123456"))

            assertTrue(helloReceived.await(2, TimeUnit.SECONDS))
            client.submitHand(sampleHand())
            assertTrue(handReceived.await(2, TimeUnit.SECONDS))
            assertEquals(listOf(CaptureMode.TRACKING), modes)
            val handJson = synchronized(messages) { messages.first { it.contains("hand_frame") } }
            val root = ProtocolCodec.json.parseToJsonElement(handJson).toString()
            assertTrue(root.contains("\"sessionId\":\"s-test\""))
            assertTrue(root.contains("\"landmarkFormat\":\"mediapipe_hand_21\""))
            assertTrue(root.contains("\"mirrorCorrected\":true"))
        } finally {
            client.disconnect()
            serverSocket.get()?.close(1000, "test complete")
            serverClosed.await(2, TimeUnit.SECONDS)
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `non retryable hello error is exposed without reconnecting`() {
        val server = MockWebServer()
        val errorReceived = CountDownLatch(1)
        val serverClosed = CountDownLatch(1)
        val serverSocket = AtomicReference<WebSocket>()
        val lastState = AtomicReference<ConnectionSnapshot>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSocket.set(webSocket)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        if (text.contains("\"messageType\":\"hello\"")) {
                            webSocket.send(
                                """{"schemaVersion":1,"messageType":"hello_error","code":"pairing_code_mismatch","retryable":false}""",
                            )
                        }
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        serverClosed.countDown()
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {
                lastState.set(it)
                if (it.status == ConnectionStatus.ERROR) errorReceived.countDown()
            },
            onModeChanged = {},
        )
        try {
            val url = server.url("/")
            client.connect(ConnectionConfig(url.host, url.port, "123456"))
            assertTrue(errorReceived.await(2, TimeUnit.SECONDS))
            assertEquals(ConnectionErrorCode.PAIRING_CODE_MISMATCH, lastState.get().errorCode)
        } finally {
            client.disconnect()
            serverSocket.get()?.close(1000, "test complete")
            serverClosed.await(2, TimeUnit.SECONDS)
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `out of range landmarks are clamped at the network boundary`() {
        val server = MockWebServer()
        val handReceived = CountDownLatch(1)
        val serverClosed = CountDownLatch(1)
        val serverSocket = AtomicReference<WebSocket>()
        val handJson = AtomicReference<String>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSocket.set(webSocket)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        if (text.contains("\"messageType\":\"hello\"")) {
                            webSocket.send(
                                """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s-clamp","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":false}""",
                            )
                        } else if (text.contains("\"messageType\":\"hand_frame\"")) {
                            handJson.set(text)
                            handReceived.countDown()
                        }
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        serverClosed.countDown()
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {},
            onModeChanged = {},
        )
        try {
            val url = server.url("/")
            client.connect(ConnectionConfig(url.host, url.port, "123456"))
            Thread.sleep(150)
            client.submitHand(
                sampleHand().copy(
                    hands = listOf(
                        sampleHand().hands.single().copy(
                            landmarks = List(21) { LandmarkPoint(-0.2f, 1.3f, -0.01f) },
                        ),
                    ),
                ),
            )
            assertTrue(handReceived.await(2, TimeUnit.SECONDS))
            val encoded = handJson.get()
            assertTrue(encoded.contains("[0.0,1.0,-0.01]"))
        } finally {
            client.disconnect()
            serverSocket.get()?.close(1000, "test complete")
            serverClosed.await(2, TimeUnit.SECONDS)
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `network recovery reconnects and reuses confirmed calibration`() {
        val server = MockWebServer()
        val firstHello = CountDownLatch(1)
        val firstCalibration = CountDownLatch(1)
        val firstTrackingStarted = CountDownLatch(1)
        val trackingStarted = CountDownLatch(2)
        val secondHello = CountDownLatch(1)
        val cachedCalibration = CountDownLatch(1)
        val serverEnded = CountDownLatch(2)
        val serverSockets = CopyOnWriteArrayList<WebSocket>()
        val modes = CopyOnWriteArrayList<CaptureMode>()

        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSockets += webSocket
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        when {
                            text.contains("\"messageType\":\"hello\"") -> {
                                firstHello.countDown()
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s-first","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":true}""",
                                )
                            }
                            text.contains("\"messageType\":\"calibration_markers\"") -> {
                                firstCalibration.countDown()
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"calibration_status","sessionId":"s-first","status":"complete"}""",
                                )
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"control_message","sessionId":"s-first","command":"set_mode","mode":"tracking"}""",
                                )
                            }
                        }
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        serverEnded.countDown()
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        serverEnded.countDown()
                    }
                },
            ),
        )
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        serverSockets += webSocket
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        when {
                            text.contains("\"messageType\":\"hello\"") -> {
                                secondHello.countDown()
                                // A conservative PC may ask again. Android must reuse the confirmed coordinates.
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"s-second","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":true}""",
                                )
                            }
                            text.contains("\"messageType\":\"calibration_markers\"") -> {
                                cachedCalibration.countDown()
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"control_message","sessionId":"s-second","command":"set_mode","mode":"tracking"}""",
                                )
                            }
                        }
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        serverEnded.countDown()
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        serverEnded.countDown()
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {},
            onModeChanged = {
                modes += it
                if (it == CaptureMode.TRACKING) {
                    firstTrackingStarted.countDown()
                    trackingStarted.countDown()
                }
            },
        )
        try {
            val url = server.url("/")
            client.connect(ConnectionConfig(url.host, url.port, "123456"))
            assertTrue(firstHello.await(2, TimeUnit.SECONDS))
            client.submitCalibration(sampleCalibration())
            assertTrue(firstCalibration.await(2, TimeUnit.SECONDS))
            assertTrue(firstTrackingStarted.await(2, TimeUnit.SECONDS))

            client.onNetworkLost()
            client.onNetworkAvailable()

            assertTrue(secondHello.await(2, TimeUnit.SECONDS))
            assertTrue(cachedCalibration.await(2, TimeUnit.SECONDS))
            assertTrue(trackingStarted.await(2, TimeUnit.SECONDS))
            assertEquals(
                listOf(
                    CaptureMode.CALIBRATION,
                    CaptureMode.TRACKING,
                    CaptureMode.CALIBRATION,
                    CaptureMode.TRACKING,
                ),
                modes.toList(),
            )
        } finally {
            client.disconnect()
            serverSockets.forEach { it.close(1000, "test complete") }
            serverEnded.await(2, TimeUnit.SECONDS)
            client.close()
            server.shutdown()
        }
    }

    @Test
    fun `manual disconnect discards confirmed calibration before a new connection`() {
        val server = MockWebServer()
        val firstTracking = CountDownLatch(1)
        val secondHello = CountDownLatch(1)
        val unexpectedCachedCalibration = CountDownLatch(1)
        val sockets = CopyOnWriteArrayList<WebSocket>()
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        sockets += webSocket
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        when {
                            text.contains("\"messageType\":\"hello\"") -> webSocket.send(
                                """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"manual-first","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":true}""",
                            )
                            text.contains("\"messageType\":\"calibration_markers\"") -> {
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"calibration_status","sessionId":"manual-first","status":"complete"}""",
                                )
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"control_message","sessionId":"manual-first","command":"set_mode","mode":"tracking"}""",
                                )
                            }
                        }
                    }
                },
            ),
        )
        server.enqueue(
            MockResponse().withWebSocketUpgrade(
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        sockets += webSocket
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        when {
                            text.contains("\"messageType\":\"hello\"") -> {
                                secondHello.countDown()
                                webSocket.send(
                                    """{"schemaVersion":1,"messageType":"hello_ack","sessionId":"manual-second","surface":{"surfaceId":"primary","widthPx":1920,"heightPx":1080},"calibrationRequired":true}""",
                                )
                            }
                            text.contains("\"messageType\":\"calibration_markers\"") ->
                                unexpectedCachedCalibration.countDown()
                        }
                    }
                },
            ),
        )
        server.start()
        val client = YubiBoardWebSocketClient(
            deviceId = "android-test",
            clientVersion = "0.1.0",
            onStateChanged = {},
            onModeChanged = { if (it == CaptureMode.TRACKING) firstTracking.countDown() },
        )
        try {
            val url = server.url("/")
            val config = ConnectionConfig(url.host, url.port, pairingToken = "123456")
            client.connect(config)
            client.submitCalibration(sampleCalibration())
            assertTrue(firstTracking.await(2, TimeUnit.SECONDS))

            client.disconnect()
            sockets.first().close(1000, "manual disconnect")
            client.connect(config)

            assertTrue(secondHello.await(2, TimeUnit.SECONDS))
            assertFalse(unexpectedCachedCalibration.await(500, TimeUnit.MILLISECONDS))
        } finally {
            client.disconnect()
            sockets.forEach { it.close(1000, "test complete") }
            client.close()
            server.shutdown()
        }
    }

    private fun sampleHand() = HandDetectionResult(
        capturedAtMonotonicMs = 100,
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
}
