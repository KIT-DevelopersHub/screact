package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.protocol.CalibrationMarkersMessage
import com.nxtend.team35.yubiboard.protocol.CameraChangedMessage
import com.nxtend.team35.yubiboard.protocol.ControlMessage
import com.nxtend.team35.yubiboard.protocol.HandFrameMessage
import com.nxtend.team35.yubiboard.protocol.HandPayload
import com.nxtend.team35.yubiboard.protocol.HeartbeatMessage
import com.nxtend.team35.yubiboard.protocol.HelloAckMessage
import com.nxtend.team35.yubiboard.protocol.HelloErrorMessage
import com.nxtend.team35.yubiboard.protocol.HelloMessage
import com.nxtend.team35.yubiboard.protocol.MarkerPayload
import com.nxtend.team35.yubiboard.protocol.ProtocolCodec
import com.nxtend.team35.yubiboard.protocol.SCHEMA_VERSION
import com.nxtend.team35.yubiboard.protocol.SourceInfo
import com.nxtend.team35.yubiboard.protocol.TWO_HAND_INTERACTION_PROFILE
import com.nxtend.team35.yubiboard.protocol.TrackedHandPayload
import com.nxtend.team35.yubiboard.protocol.CalibrationStatusMessage
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
    private val onCalibrationStatus: (CalibrationStatusMessage) -> Unit = {},
    private val onTrustedConnectionIssued: (ConnectionConfig, String) -> Unit = { _, _ -> },
    private val onTrustedConnectionInvalid: () -> Unit = {},
    private val onCalibrationReuseQueued: () -> Unit = {},
    private val onInteractionProfileChanged: (Boolean) -> Unit = {},
    private val onLog: (String) -> Unit = {},
    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(10, TimeUnit.SECONDS)
        .build(),
    private val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(),
) : AutoCloseable {
    private val lock = Any()
    private val frameId = AtomicLong(0)
    private val targetFrameIntervalMs = AtomicLong(FRAME_INTERVAL_MS)
    private val lastHandSentAtMs = AtomicLong(0)
    private val latestHand = AtomicReference<HandDetectionResult?>()
    private val latestCalibration = AtomicReference<MarkerDetectionResult?>()
    private val lastStableCalibration = AtomicReference<MarkerDetectionResult?>()
    private var desiredConfig: ConnectionConfig? = null
    private var automaticConnection = false
    private var webSocket: WebSocket? = null
    private var sessionId: String? = null
    private var reconnectAttempt = 0
    private var heartbeatTask: ScheduledFuture<*>? = null
    private var reconnectTask: ScheduledFuture<*>? = null
    private var countdownTask: ScheduledFuture<*>? = null
    private var manuallyStopped = true
    private var pendingErrorCode: ConnectionErrorCode? = null
    private var calibrationConfirmed = false
    private var calibrationRequested = false
    @Volatile
    private var cameraFacing = "back"

    init {
        scheduler.scheduleAtFixedRate(::flushLatestHand, 0, SENDER_TICK_MS, TimeUnit.MILLISECONDS)
        scheduler.scheduleAtFixedRate(
            ::flushLatestCalibration,
            0,
            CALIBRATION_INTERVAL_MS,
            TimeUnit.MILLISECONDS,
        )
    }

    fun connect(config: ConnectionConfig, automatic: Boolean = false) {
        require(config.validate() == null) { config.validate().orEmpty() }
        synchronized(lock) {
            AppDiagnostics.event(
                "network",
                "connect_requested",
                mapOf("host" to config.host, "port" to config.port),
            )
            manuallyStopped = false
            desiredConfig = config
            automaticConnection = automatic
            reconnectAttempt = 0
            calibrationConfirmed = false
            calibrationRequested = false
            lastStableCalibration.set(null)
            heartbeatTask?.cancel(false)
            reconnectTask?.cancel(false)
            countdownTask?.cancel(false)
            webSocket?.cancel()
            openSocket(config, reconnecting = false)
        }
    }

    fun submitHand(result: HandDetectionResult) {
        if (latestHand.getAndSet(result) != null) AppDiagnostics.increment("network.hand_replaced")
    }

    fun submitCalibration(result: MarkerDetectionResult) {
        if (result.stable) {
            lastStableCalibration.set(result)
            if (latestCalibration.getAndSet(result) != null) {
                AppDiagnostics.increment("network.calibration_replaced")
            }
        }
    }

    fun notifyCameraChanged(usingFrontCamera: Boolean) {
        synchronized(lock) {
            cameraFacing = if (usingFrontCamera) "front" else "back"
            latestHand.set(null)
            latestCalibration.set(null)
            lastStableCalibration.set(null)
            calibrationConfirmed = false
            calibrationRequested = true
            val socket = webSocket ?: return
            val activeSession = sessionId ?: return
            val encoded = ProtocolCodec.encode(
                CameraChangedMessage(
                    sessionId = activeSession,
                    cameraFacing = cameraFacing,
                    changedAtMonotonicMs = monotonicMs(),
                ),
            )
            if (socket.send(encoded)) {
                AppDiagnostics.event("network", "camera_changed", mapOf("facing" to cameraFacing))
            } else {
                AppDiagnostics.increment("network.send_failures")
            }
        }
    }

    fun setCameraFacing(usingFrontCamera: Boolean) {
        cameraFacing = if (usingFrontCamera) "front" else "back"
    }

    fun setMaxFrameRate(framesPerSecond: Int) {
        require(framesPerSecond in 5..20)
        targetFrameIntervalMs.set(1_000L / framesPerSecond)
    }

    fun disconnect() {
        synchronized(lock) {
            AppDiagnostics.event("network", "disconnect_requested")
            manuallyStopped = true
            desiredConfig = null
            automaticConnection = false
            sessionId = null
            latestHand.set(null)
            latestCalibration.set(null)
            lastStableCalibration.set(null)
            calibrationConfirmed = false
            calibrationRequested = false
            heartbeatTask?.cancel(false)
            reconnectTask?.cancel(false)
            countdownTask?.cancel(false)
            webSocket?.close(NORMAL_CLOSE_CODE, "user disconnect")
            webSocket = null
            publish(ConnectionSnapshot(ConnectionStatus.DISCONNECTED))
        }
    }

    fun retryNow() {
        synchronized(lock) {
            val config = desiredConfig ?: return
            if (manuallyStopped || sessionId != null) return
            reconnectTask?.cancel(false)
            countdownTask?.cancel(false)
            webSocket?.cancel()
            openSocket(config, reconnecting = true)
        }
    }

    fun onNetworkLost() {
        synchronized(lock) {
            if (manuallyStopped || desiredConfig == null) return
            AppDiagnostics.event("network", "default_network_lost")
            sessionId = null
            heartbeatTask?.cancel(false)
            reconnectTask?.cancel(false)
            countdownTask?.cancel(false)
            webSocket?.cancel()
            webSocket = null
            publish(
                ConnectionSnapshot(
                    status = ConnectionStatus.RECONNECTING,
                    detail = "ネットワーク接続を待っています",
                    errorCode = ConnectionErrorCode.UNREACHABLE,
                ),
            )
        }
    }

    fun onNetworkAvailable() {
        synchronized(lock) {
            val config = desiredConfig ?: return
            if (manuallyStopped || sessionId != null) return
            AppDiagnostics.event("network", "default_network_available")
            reconnectTask?.cancel(false)
            countdownTask?.cancel(false)
            webSocket?.cancel()
            openSocket(config, reconnecting = true)
        }
    }

    private fun openSocket(config: ConnectionConfig, reconnecting: Boolean) {
        countdownTask?.cancel(false)
        AppDiagnostics.event(
            "network",
            if (reconnecting) "reconnect_started" else "socket_started",
            mapOf("attempt" to reconnectAttempt),
        )
        publish(
            ConnectionSnapshot(
                status = if (reconnecting) ConnectionStatus.RECONNECTING else ConnectionStatus.CONNECTING,
                automatic = automaticConnection,
            ),
        )
        sessionId = null
        val request = Request.Builder().url(config.webSocketUrl).build()
        val listener = SocketListener(config, reconnecting)
        val openedSocket = httpClient.newWebSocket(request, listener)
        webSocket = openedSocket
        scheduler.schedule(
            {
                synchronized(lock) {
                    if (webSocket === openedSocket && sessionId == null && !manuallyStopped) {
                        AppDiagnostics.increment("network.ack_timeouts")
                        AppDiagnostics.event("network", "hello_ack_timeout")
                        onLog("hello_ack timeout")
                        pendingErrorCode = ConnectionErrorCode.ACK_TIMEOUT
                        openedSocket.cancel()
                    }
                }
            },
            ACK_TIMEOUT_SECONDS,
            TimeUnit.SECONDS,
        )
    }

    private fun flushLatestHand() {
        val now = monotonicMs()
        if (now - lastHandSentAtMs.get() < targetFrameIntervalMs.get()) return
        val socket: WebSocket
        val activeSession: String
        synchronized(lock) {
            socket = webSocket ?: return
            activeSession = sessionId ?: return
        }
        val queueBytes = socket.queueSize()
        AppDiagnostics.gauge("network.queue_bytes", queueBytes)
        if (queueBytes > MAX_QUEUE_BYTES) {
            AppDiagnostics.increment("network.queue_throttled")
            return
        }
        val result = latestHand.getAndSet(null) ?: return
        if (!isValidHandFrame(result)) {
            AppDiagnostics.increment("network.invalid_hand_frames")
            AppDiagnostics.event("network", "invalid_hand_frame_dropped")
            return
        }
        val hadOutOfRange = result.hands.any { hand ->
            hand.landmarks.any { it.x !in 0f..1f || it.y !in 0f..1f }
        }
        if (hadOutOfRange) {
            AppDiagnostics.increment("network.landmarks_clamped")
            AppDiagnostics.sampled(
                "landmarks_clamped",
                "network",
                "landmarks_clamped",
                mapOf("trackIds" to result.hands.map { it.trackId }),
            )
        }
        val hands = result.hands.sortedBy { it.trackId }.map { tracked ->
            TrackedHandPayload(
                trackId = tracked.trackId,
                handedness = tracked.handedness,
                handednessScore = tracked.handednessScore,
                landmarks = tracked.landmarks.map {
                    listOf(it.x.coerceIn(0f, 1f), it.y.coerceIn(0f, 1f), it.z)
                },
            )
        }
        val primary = hands.firstOrNull()
        val message = HandFrameMessage(
            sessionId = activeSession,
            frameId = frameId.incrementAndGet(),
            capturedAtMonotonicMs = result.capturedAtMonotonicMs,
            source = SourceInfo(
                result.sourceWidth,
                result.sourceHeight,
                mirrorCorrected = result.mirrorCorrected,
                cameraFacing = result.cameraFacing,
            ),
            hands = hands,
            hand = if (primary != null) {
                HandPayload(
                    detected = true,
                    handedness = primary.handedness,
                    handednessScore = primary.handednessScore,
                    landmarks = primary.landmarks,
                )
            } else {
                HandPayload(detected = false)
            },
        )
        val encoded = ProtocolCodec.encode(message)
        if (socket.send(encoded)) {
            lastHandSentAtMs.set(now)
            AppDiagnostics.increment("network.hand_sent")
            AppDiagnostics.increment("network.bytes_sent", encoded.toByteArray().size.toLong())
            AppDiagnostics.gauge("network.last_frame_id", message.frameId)
            AppDiagnostics.gauge(
                "network.capture_to_send_ms",
                (now - result.capturedAtMonotonicMs).coerceAtLeast(0),
            )
            AppDiagnostics.metric(
                "network.capture_to_send_ms",
                (now - result.capturedAtMonotonicMs).coerceAtLeast(0),
            )
            AppDiagnostics.sampled(
                "hand_sent",
                "network",
                "hand_frame_sent",
                mapOf(
                    "frameId" to message.frameId,
                    "detected" to result.detected,
                    "handCount" to hands.size,
                    "trackIds" to hands.map { it.trackId },
                    "bytes" to encoded.toByteArray().size,
                    "captureToSendMs" to (now - result.capturedAtMonotonicMs).coerceAtLeast(0),
                ),
            )
        } else {
            AppDiagnostics.increment("network.send_failures")
            latestHand.compareAndSet(null, result)
        }
    }

    private fun isValidHandFrame(result: HandDetectionResult): Boolean =
        result.hands.size <= 2 &&
            result.hands.map { it.trackId }.let { ids ->
                ids.all { it > 0 } && ids.distinct().size == ids.size
            } &&
            result.hands.all { hand ->
                hand.landmarks.size == 21 &&
                    hand.landmarks.all { it.x.isFinite() && it.y.isFinite() && it.z.isFinite() } &&
                    (hand.handednessScore == null ||
                        hand.handednessScore.isFinite() && hand.handednessScore in 0f..1f)
            }

    private fun startHeartbeat(socket: WebSocket, activeSession: String) {
        heartbeatTask?.cancel(false)
        heartbeatTask = scheduler.scheduleAtFixedRate(
            {
                val encoded = ProtocolCodec.encode(
                        HeartbeatMessage(
                            sessionId = activeSession,
                            sentAtMonotonicMs = monotonicMs(),
                        ),
                    )
                if (socket.send(encoded)) {
                    AppDiagnostics.increment("network.heartbeats_sent")
                    AppDiagnostics.increment("network.bytes_sent", encoded.toByteArray().size.toLong())
                }
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
        if (socket.queueSize() > MAX_QUEUE_BYTES) {
            AppDiagnostics.increment("network.queue_throttled")
            return
        }
        val result = latestCalibration.getAndSet(null) ?: return
        val message = CalibrationMarkersMessage(
            sessionId = activeSession,
            capturedAtMonotonicMs = result.capturedAtMonotonicMs,
            source = SourceInfo(
                result.sourceWidth,
                result.sourceHeight,
                mirrorCorrected = result.mirrorCorrected,
                cameraFacing = result.cameraFacing,
            ),
            markers = result.markers.map { marker ->
                MarkerPayload(
                    id = marker.id,
                    center = listOf(marker.center.x, marker.center.y),
                    corners = marker.corners.map { listOf(it.x, it.y) },
                )
            },
        )
        val encoded = ProtocolCodec.encode(message)
        if (!socket.send(encoded)) {
            AppDiagnostics.increment("network.send_failures")
            latestCalibration.compareAndSet(null, result)
        } else {
            AppDiagnostics.increment("network.calibration_sent")
            AppDiagnostics.increment("network.bytes_sent", encoded.toByteArray().size.toLong())
            AppDiagnostics.event(
                "network",
                "calibration_sent",
                mapOf("markers" to result.markers.size, "bytes" to encoded.toByteArray().size),
            )
        }
    }

    private fun handleServerMessage(socket: WebSocket, text: String, reconnecting: Boolean) {
        val message = runCatching { ProtocolCodec.decodeServerMessage(text) }
            .onFailure {
                AppDiagnostics.increment("network.invalid_messages")
                AppDiagnostics.event("network", "invalid_server_json", mapOf("message" to it.message))
                onLog("Invalid server JSON: ${it.message}")
            }
            .getOrNull() ?: return
        when (message) {
            is HelloAckMessage -> synchronized(lock) {
                if (message.schemaVersion != SCHEMA_VERSION || webSocket !== socket) return
                message.resumeToken?.let { token ->
                    val activeConfig = desiredConfig ?: return
                    onTrustedConnectionIssued(activeConfig, token)
                }
                sessionId = message.sessionId
                val supportsTwoHands =
                    message.acceptedInteractionProfile == TWO_HAND_INTERACTION_PROFILE
                onInteractionProfileChanged(supportsTwoHands)
                val cachedCalibration = lastStableCalibration.get()
                val reuseCalibration = reconnecting && calibrationConfirmed && cachedCalibration != null
                calibrationRequested = message.calibrationRequired && !reuseCalibration
                AppDiagnostics.event(
                    "network",
                    "hello_ack",
                    mapOf(
                        "sessionId" to message.sessionId,
                        "calibrationRequired" to message.calibrationRequired,
                        "calibrationReused" to reuseCalibration,
                        "acceptedInteractionProfile" to message.acceptedInteractionProfile,
                    ),
                )
                AppDiagnostics.gauge("network.session_id", message.sessionId)
                reconnectAttempt = 0
                publish(ConnectionSnapshot(ConnectionStatus.CONNECTED, message.sessionId))
                if (reuseCalibration) {
                    latestCalibration.set(cachedCalibration)
                    AppDiagnostics.event("network", "cached_calibration_queued")
                    onModeChanged(CaptureMode.CALIBRATION)
                    onCalibrationReuseQueued()
                } else {
                    onModeChanged(
                        if (message.calibrationRequired) CaptureMode.CALIBRATION else CaptureMode.TRACKING,
                    )
                }
                startHeartbeat(socket, message.sessionId)
            }

            is HelloErrorMessage -> synchronized(lock) {
                if (message.schemaVersion != SCHEMA_VERSION || webSocket !== socket) return
                val errorCode = when (message.code) {
                    "pairing_code_mismatch" -> ConnectionErrorCode.PAIRING_CODE_MISMATCH
                    "unsupported_version" -> ConnectionErrorCode.UNSUPPORTED_VERSION
                    "server_busy" -> ConnectionErrorCode.SERVER_BUSY
                    "resume_token_invalid" -> ConnectionErrorCode.RESUME_TOKEN_INVALID
                    else -> ConnectionErrorCode.UNKNOWN
                }
                AppDiagnostics.event(
                    "network",
                    "hello_error",
                    mapOf("code" to message.code, "retryable" to message.retryable),
                )
                if (message.retryable) {
                    pendingErrorCode = errorCode
                    socket.cancel()
                } else {
                    manuallyStopped = true
                    desiredConfig = null
                    sessionId = null
                    socket.close(NORMAL_CLOSE_CODE, "hello rejected")
                    webSocket = null
                    if (errorCode == ConnectionErrorCode.RESUME_TOKEN_INVALID) {
                        automaticConnection = false
                        onTrustedConnectionInvalid()
                        publish(
                            ConnectionSnapshot(
                                ConnectionStatus.DISCONNECTED,
                                detail = "保存済みの接続情報が無効です。6桁コードで接続し直してください。",
                                errorCode = errorCode,
                            ),
                        )
                    } else {
                        publish(ConnectionSnapshot(ConnectionStatus.ERROR, errorCode = errorCode))
                    }
                }
            }

            is CalibrationStatusMessage -> synchronized(lock) {
                if (message.schemaVersion != SCHEMA_VERSION || message.sessionId != sessionId) {
                    AppDiagnostics.increment("network.ignored_calibration_status")
                    return
                }
                AppDiagnostics.event(
                    "network",
                    "calibration_status",
                    mapOf("status" to message.status, "reason" to message.reason),
                )
                when (message.status) {
                    "complete" -> {
                        calibrationConfirmed = true
                        calibrationRequested = false
                    }
                    "retry_required" -> calibrationConfirmed = false
                }
                onCalibrationStatus(message)
            }

            is ControlMessage -> synchronized(lock) {
                if (message.sessionId != sessionId) {
                    AppDiagnostics.increment("network.ignored_controls")
                    onLog("Ignored control message for another session")
                    return
                }
                when (message.command) {
                    "set_mode" -> when (message.mode) {
                        "calibration" -> {
                            calibrationConfirmed = false
                            calibrationRequested = true
                            AppDiagnostics.event("network", "remote_mode", mapOf("mode" to "calibration"))
                            onModeChanged(CaptureMode.CALIBRATION)
                        }
                        "tracking" -> {
                            if (calibrationRequested && lastStableCalibration.get() != null) {
                                calibrationConfirmed = true
                            }
                            calibrationRequested = false
                            AppDiagnostics.event("network", "remote_mode", mapOf("mode" to "tracking"))
                            onModeChanged(CaptureMode.TRACKING)
                        }
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
            AppDiagnostics.increment("network.disconnects")
            AppDiagnostics.event("network", "socket_ended", mapOf("detail" to detail))
            sessionId = null
            heartbeatTask?.cancel(false)
            val errorCode = pendingErrorCode ?: ConnectionErrorCode.UNREACHABLE
            pendingErrorCode = null
            scheduleReconnect(detail, errorCode)
        }
    }

    private fun scheduleReconnect(detail: String, errorCode: ConnectionErrorCode) {
        val config = desiredConfig ?: return
        val delayMs = RETRY_DELAYS_MS[reconnectAttempt.coerceAtMost(RETRY_DELAYS_MS.lastIndex)]
        val deadlineMs = monotonicMs() + delayMs
        reconnectAttempt++
        AppDiagnostics.gauge("network.reconnect_attempt", reconnectAttempt)
        AppDiagnostics.event(
            "network",
            "reconnect_scheduled",
            mapOf("delayMs" to delayMs, "detail" to detail),
        )
        publish(
            ConnectionSnapshot(
                status = ConnectionStatus.RECONNECTING,
                retryInSeconds = (delayMs / 1_000).toInt(),
                detail = detail,
                errorCode = errorCode,
                automatic = automaticConnection,
            ),
        )
        reconnectTask?.cancel(false)
        countdownTask?.cancel(false)
        countdownTask = scheduler.scheduleAtFixedRate(
            {
                synchronized(lock) {
                    if (manuallyStopped || desiredConfig != config) return@synchronized
                    val remaining = ((deadlineMs - monotonicMs()).coerceAtLeast(0) + 999) / 1_000
                    publish(
                        ConnectionSnapshot(
                            status = ConnectionStatus.RECONNECTING,
                            retryInSeconds = remaining.toInt(),
                            detail = detail,
                            errorCode = errorCode,
                            automatic = automaticConnection,
                        ),
                    )
                }
            },
            1,
            1,
            TimeUnit.SECONDS,
        )
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

    private fun publish(snapshot: ConnectionSnapshot) {
        AppDiagnostics.gauge("network.status", snapshot.status)
        AppDiagnostics.sampled(
            "connection_status_${snapshot.status}",
            "network",
            "state",
            mapOf("status" to snapshot.status, "detail" to snapshot.detail),
        )
        onStateChanged(snapshot)
    }

    override fun close() {
        disconnect()
        scheduler.shutdownNow()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }

    private inner class SocketListener(
        private val config: ConnectionConfig,
        private val reconnecting: Boolean,
    ) : WebSocketListener() {

        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(lock) {
                if (this@YubiBoardWebSocketClient.webSocket !== webSocket || manuallyStopped) return
                publish(
                    ConnectionSnapshot(
                        ConnectionStatus.AWAITING_ACK,
                        automatic = automaticConnection,
                    ),
                )
                val encoded = ProtocolCodec.encode(
                        HelloMessage(
                            deviceId = deviceId,
                            clientVersion = clientVersion,
                            pairingToken = config.pairingToken,
                            resumeToken = config.resumeToken,
                            cameraFacing = cameraFacing,
                        ),
                    )
                webSocket.send(encoded)
                AppDiagnostics.increment("network.bytes_sent", encoded.toByteArray().size.toLong())
                AppDiagnostics.event("network", "hello_sent", mapOf("bytes" to encoded.toByteArray().size))
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            handleServerMessage(webSocket, text, reconnecting)
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
        private const val SENDER_TICK_MS = 20L
        private const val CALIBRATION_INTERVAL_MS = 200L
        private const val MAX_QUEUE_BYTES = 256L * 1024L
        private val RETRY_DELAYS_MS = longArrayOf(1_000, 2_000, 4_000, 8_000, 10_000)

        private fun monotonicMs(): Long = System.nanoTime() / 1_000_000L
    }
}
