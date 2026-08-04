package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.protocol.CalibrationMarkersMessage
import com.nxtend.team35.yubiboard.protocol.ControlMessage
import com.nxtend.team35.yubiboard.protocol.HandFrameMessage
import com.nxtend.team35.yubiboard.protocol.HandPayload
import com.nxtend.team35.yubiboard.protocol.HeartbeatMessage
import com.nxtend.team35.yubiboard.protocol.HelloAckMessage
import com.nxtend.team35.yubiboard.protocol.HelloMessage
import com.nxtend.team35.yubiboard.protocol.MarkerPayload
import com.nxtend.team35.yubiboard.protocol.ProtocolCodec
import com.nxtend.team35.yubiboard.protocol.SCHEMA_VERSION
import com.nxtend.team35.yubiboard.protocol.SourceInfo
import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.MarkerDetectionResult
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class YubiBoardWebSocketClient(
    private val deviceId: String,
    private val clientVersion: String,
    private val onStateChanged: (ConnectionSnapshot) -> Unit,
    private val onModeChanged: (CaptureMode) -> Unit,
    private val onLog: (String) -> Unit = {},
    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(10, TimeUnit.SECONDS)
        .build(),
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(),
) : AutoCloseable {
    private val lock = Any()
    private val frameId = AtomicLong(0)
    private val latestHand = AtomicReference<HandDetectionResult?>()
    private val latestCalibration = AtomicReference<MarkerDetectionResult?>()
    private var desiredConfig: ConnectionConfig? = null
    private var webSocket: WebSocket? = null
    private var sessionId: String? = null
    private var reconnectAttempt = 0
    private var heartbeatTask: ScheduledFuture<*>? = null
    private var reconnectTask: ScheduledFuture<*>? = null
    private var manuallyStopped = true

    init {
        scheduler.scheduleAtFixedRate(::flushLatestHand, 0, FRAME_INTERVAL_MS, TimeUnit.MILLISECONDS)
        scheduler.scheduleAtFixedRate(
            ::flushLatestCalibration,
            0,
            CALIBRATION_INTERVAL_MS,
            TimeUnit.MILLISECONDS,
        )
    }

    fun connect(config: ConnectionConfig) {
        require(config.validate() == null) { config.validate().orEmpty() }
        synchronized(lock) {
            manuallyStopped = false
            desiredConfig = config
            reconnectAttempt = 0
            heartbeatTask?.cancel(false)
            reconnectTask?.cancel(false)
            webSocket?.cancel()
            openSocket(config, reconnecting = false)
        }
    }

    fun submitHand(result: HandDetectionResult) {
        latestHand.set(result)
    }

    fun submitCalibration(result: MarkerDetectionResult) {
        if (result.stable) latestCalibration.set(result)
    }

    fun disconnect() {
        synchronized(lock) {
            manuallyStopped = true
            desiredConfig = null
            sessionId = null
            latestHand.set(null)
            latestCalibration.set(null)
            heartbeatTask?.cancel(false)
            reconnectTask?.cancel(false)
            webSocket?.close(NORMAL_CLOSE_CODE, "user disconnect")
            webSocket = null
            publish(ConnectionSnapshot(ConnectionStatus.DISCONNECTED))
        }
    }

    private fun openSocket(config: ConnectionConfig, reconnecting: Boolean) {
        publish(
            ConnectionSnapshot(
                status = if (reconnecting) ConnectionStatus.RECONNECTING else ConnectionStatus.CONNECTING,
            ),
        )
        sessionId = null
        val request = Request.Builder().url(config.webSocketUrl).build()
        val listener = SocketListener(config)
        webSocket = httpClient.newWebSocket(request, listener)
        scheduler.schedule(
            {
                synchronized(lock) {
                    if (webSocket === listener.socket && sessionId == null && !manuallyStopped) {
                        onLog("hello_ack timeout")
                        listener.socket?.cancel()
                    }
                }
            },
            ACK_TIMEOUT_SECONDS,
            TimeUnit.SECONDS,
        )
    }

    private fun flushLatestHand() {
        val socket: WebSocket
        val activeSession: String
        synchronized(lock) {
            socket = webSocket ?: return
            activeSession = sessionId ?: return
        }
        if (socket.queueSize() > MAX_QUEUE_BYTES) return
        val result = latestHand.getAndSet(null) ?: return
        val message = HandFrameMessage(
            sessionId = activeSession,
            frameId = frameId.incrementAndGet(),
            capturedAtMonotonicMs = result.capturedAtMonotonicMs,
            source = SourceInfo(result.sourceWidth, result.sourceHeight),
            hand = if (result.detected) {
                HandPayload(
                    detected = true,
                    handedness = result.handedness,
                    handednessScore = result.handednessScore,
                    landmarks = result.landmarks.map { listOf(it.x, it.y, it.z) },
                )
            } else {
                HandPayload(detected = false)
            },
        )
        if (!socket.send(ProtocolCodec.encode(message))) latestHand.compareAndSet(null, result)
    }

    private fun startHeartbeat(socket: WebSocket, activeSession: String) {
        heartbeatTask?.cancel(false)
        heartbeatTask = scheduler.scheduleAtFixedRate(
            {
                socket.send(
                    ProtocolCodec.encode(
                        HeartbeatMessage(
                            sessionId = activeSession,
                            sentAtMonotonicMs = monotonicMs(),
                        ),
                    ),
                )
            },
            HEARTBEAT_SECONDS,
            HEARTBEAT_SECONDS,
            TimeUnit.SECONDS,
        )
    }

    private fun flushLatestCalibration() {
        val socket: WebSocket
        val activeSession: String
        synchronized(lock) {
            socket = webSocket ?: return
            activeSession = sessionId ?: return
        }
        if (socket.queueSize() > MAX_QUEUE_BYTES) return
        val result = latestCalibration.getAndSet(null) ?: return
        val message = CalibrationMarkersMessage(
            sessionId = activeSession,
            capturedAtMonotonicMs = result.capturedAtMonotonicMs,
            source = SourceInfo(result.sourceWidth, result.sourceHeight),
            markers = result.markers.map { marker ->
                MarkerPayload(
                    id = marker.id,
                    center = listOf(marker.center.x, marker.center.y),
                    corners = marker.corners.map { listOf(it.x, it.y) },
                )
            },
        )
        if (!socket.send(ProtocolCodec.encode(message))) {
            latestCalibration.compareAndSet(null, result)
        }
    }

    private fun handleServerMessage(socket: WebSocket, text: String) {
        val message = runCatching { ProtocolCodec.decodeServerMessage(text) }
            .onFailure { onLog("Invalid server JSON: ${it.message}") }
            .getOrNull() ?: return
        when (message) {
            is HelloAckMessage -> synchronized(lock) {
                if (message.schemaVersion != SCHEMA_VERSION || webSocket !== socket) return
                sessionId = message.sessionId
                reconnectAttempt = 0
                publish(ConnectionSnapshot(ConnectionStatus.CONNECTED, message.sessionId))
                onModeChanged(
                    if (message.calibrationRequired) CaptureMode.CALIBRATION else CaptureMode.TRACKING,
                )
                startHeartbeat(socket, message.sessionId)
            }

            is ControlMessage -> synchronized(lock) {
                if (message.sessionId != sessionId) {
                    onLog("Ignored control message for another session")
                    return
                }
                when (message.command) {
                    "set_mode" -> when (message.mode) {
                        "calibration" -> onModeChanged(CaptureMode.CALIBRATION)
                        "tracking" -> onModeChanged(CaptureMode.TRACKING)
                        else -> onLog("Unknown capture mode: ${message.mode}")
                    }

                    "disconnect" -> disconnect()
                    else -> onLog("Unknown control command: ${message.command}")
                }
            }
        }
    }

    private fun handleSocketEnded(socket: WebSocket, detail: String) {
        synchronized(lock) {
            if (webSocket !== socket || manuallyStopped) return
            sessionId = null
            heartbeatTask?.cancel(false)
            scheduleReconnect(detail)
        }
    }

    private fun scheduleReconnect(detail: String) {
        val config = desiredConfig ?: return
        val delayMs = RETRY_DELAYS_MS[reconnectAttempt.coerceAtMost(RETRY_DELAYS_MS.lastIndex)]
        reconnectAttempt++
        publish(
            ConnectionSnapshot(
                status = ConnectionStatus.RECONNECTING,
                retryInSeconds = (delayMs / 1_000).toInt(),
                detail = detail,
            ),
        )
        reconnectTask?.cancel(false)
        reconnectTask = scheduler.schedule(
            {
                synchronized(lock) {
                    if (!manuallyStopped && desiredConfig == config) openSocket(config, reconnecting = true)
                }
            },
            delayMs,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun publish(snapshot: ConnectionSnapshot) = onStateChanged(snapshot)

    override fun close() {
        disconnect()
        scheduler.shutdownNow()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }

    private inner class SocketListener(private val config: ConnectionConfig) : WebSocketListener() {
        var socket: WebSocket? = null

        override fun onOpen(webSocket: WebSocket, response: Response) {
            socket = webSocket
            synchronized(lock) {
                if (this@YubiBoardWebSocketClient.webSocket !== webSocket || manuallyStopped) return
                publish(ConnectionSnapshot(ConnectionStatus.AWAITING_ACK))
                webSocket.send(
                    ProtocolCodec.encode(
                        HelloMessage(
                            deviceId = deviceId,
                            clientVersion = clientVersion,
                            pairingToken = config.pairingToken,
                        ),
                    ),
                )
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            handleServerMessage(webSocket, text)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            handleSocketEnded(webSocket, "接続が閉じられました: $code $reason")
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            handleSocketEnded(webSocket, t.message ?: "通信エラー")
        }
    }

    companion object {
        private const val NORMAL_CLOSE_CODE = 1000
        private const val ACK_TIMEOUT_SECONDS = 5L
        private const val HEARTBEAT_SECONDS = 5L
        private const val FRAME_INTERVAL_MS = 50L
        private const val CALIBRATION_INTERVAL_MS = 200L
        private const val MAX_QUEUE_BYTES = 256L * 1024L
        private val RETRY_DELAYS_MS = longArrayOf(1_000, 2_000, 4_000, 8_000, 10_000)

        private fun monotonicMs(): Long = System.nanoTime() / 1_000_000L
    }
}
