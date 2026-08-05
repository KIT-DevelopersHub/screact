package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.protocol.ProtocolCodec
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.LandmarkPoint
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class YubiBoardWebSocketClientTest {
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
                    landmarks = List(21) { LandmarkPoint(-0.2f, 1.3f, -0.01f) },
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

    private fun sampleHand() = HandDetectionResult(
        capturedAtMonotonicMs = 100,
        sourceWidth = 640,
        sourceHeight = 480,
        detected = true,
        landmarks = List(21) { LandmarkPoint(0.5f, 0.5f, 0f) },
        handedness = "RIGHT",
        handednessScore = 0.9f,
    )
}
