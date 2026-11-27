package com.nxtend.team35.yubiboard.network

import com.nxtend.team35.yubiboard.protocol.CalibrationStatusMessage
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import okhttp3.OkHttpClient
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * WebSocket（OkHttp）で Desktop へつなぐ入力クライアント。
 * セッション処理は [InputSession]、通信路は [OkHttpWebSocketTransport] が持つ。
 */
class YubiBoardWebSocketClient(
    deviceId: String,
    clientVersion: String,
    onStateChanged: (ConnectionSnapshot) -> Unit,
    onModeChanged: (CaptureMode) -> Unit,
    onCalibrationStatus: (CalibrationStatusMessage) -> Unit = {},
    onTrustedConnectionIssued: (ConnectionConfig, String) -> Unit = { _, _ -> },
    onTrustedConnectionInvalid: () -> Unit = {},
    onCalibrationReuseQueued: () -> Unit = {},
    onInteractionProfileChanged: (Boolean) -> Unit = {},
    onLog: (String) -> Unit = {},
    httpClient: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(10, TimeUnit.SECONDS)
        .build(),
    scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(),
) : InputSession(
    transport = OkHttpWebSocketTransport(httpClient),
    deviceId = deviceId,
    clientVersion = clientVersion,
    onStateChanged = onStateChanged,
    onModeChanged = onModeChanged,
    onCalibrationStatus = onCalibrationStatus,
    onTrustedConnectionIssued = onTrustedConnectionIssued,
    onTrustedConnectionInvalid = onTrustedConnectionInvalid,
    onCalibrationReuseQueued = onCalibrationReuseQueued,
    onInteractionProfileChanged = onInteractionProfileChanged,
    onLog = onLog,
    scheduler = scheduler,
)
