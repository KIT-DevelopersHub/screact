package com.nxtend.team35.yubiboard.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.nxtend.team35.yubiboard.BuildConfig
import com.nxtend.team35.yubiboard.network.ConnectionErrorCode
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode

@Composable
fun ProductionScreen(
    state: ProductionUiState,
    savedHost: String,
    savedPort: Int,
    hasTrustedPc: Boolean,
    cameraPermissionPermanentlyDenied: Boolean,
    previewContent: @Composable () -> Unit,
    onRequestCameraPermission: () -> Unit,
    onOpenSystemSettings: () -> Unit,
    onRetryCamera: () -> Unit,
    onConnect: (String, String, String) -> String?,
    onCancelConnection: () -> Unit,
    onDisconnect: () -> Unit,
    onRetryNow: () -> Unit,
    onChangeConnectionSettings: () -> Unit,
    onForgetTrustedPc: () -> Unit,
    onOpenDebug: () -> Unit,
    onExitDebug: () -> Unit = {},
    onOpenDebugSettings: () -> Unit = {},
    onOpenDiagnostics: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var host by rememberSaveable { mutableStateOf(savedHost.ifBlank { "127.0.0.1" }) }
    var port by rememberSaveable { mutableStateOf(savedPort.toString()) }
    var token by rememberSaveable { mutableStateOf("") }
    var formError by remember { mutableStateOf<String?>(null) }
    var showHelp by rememberSaveable { mutableStateOf(false) }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .safeDrawingPadding(),
    ) {
        val portrait = maxHeight >= maxWidth
        if (portrait) {
            Column(Modifier.fillMaxSize()) {
                PreviewPane(Modifier.fillMaxWidth().weight(1f), previewContent)
                ProductionGuidePanel(
                    state = state,
                    host = host,
                    port = port,
                    token = token,
                    formError = formError,
                    cameraPermissionPermanentlyDenied = cameraPermissionPermanentlyDenied,
                    onHostChange = { host = it },
                    onPortChange = { port = it.filter(Char::isDigit).take(5) },
                    onTokenChange = { token = it.filter(Char::isDigit).take(6) },
                    onConnect = { formError = onConnect(host, port, token) },
                    onRequestCameraPermission = onRequestCameraPermission,
                    onOpenSystemSettings = onOpenSystemSettings,
                    onRetryCamera = onRetryCamera,
                    onCancelConnection = onCancelConnection,
                    onDisconnect = onDisconnect,
                    onRetryNow = onRetryNow,
                    onChangeConnectionSettings = onChangeConnectionSettings,
                    onShowHelp = { showHelp = true },
                    onOpenDebug = onOpenDebug,
                    onExitDebug = onExitDebug,
                    onOpenDebugSettings = onOpenDebugSettings,
                    onOpenDiagnostics = onOpenDiagnostics,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                )
            }
        } else {
            Row(Modifier.fillMaxSize()) {
                PreviewPane(Modifier.weight(1.6f).fillMaxHeight(), previewContent)
                ProductionGuidePanel(
                    state = state,
                    host = host,
                    port = port,
                    token = token,
                    formError = formError,
                    cameraPermissionPermanentlyDenied = cameraPermissionPermanentlyDenied,
                    onHostChange = { host = it },
                    onPortChange = { port = it.filter(Char::isDigit).take(5) },
                    onTokenChange = { token = it.filter(Char::isDigit).take(6) },
                    onConnect = { formError = onConnect(host, port, token) },
                    onRequestCameraPermission = onRequestCameraPermission,
                    onOpenSystemSettings = onOpenSystemSettings,
                    onRetryCamera = onRetryCamera,
                    onCancelConnection = onCancelConnection,
                    onDisconnect = onDisconnect,
                    onRetryNow = onRetryNow,
                    onChangeConnectionSettings = onChangeConnectionSettings,
                    onShowHelp = { showHelp = true },
                    onOpenDebug = onOpenDebug,
                    onExitDebug = onExitDebug,
                    onOpenDebugSettings = onOpenDebugSettings,
                    onOpenDiagnostics = onOpenDiagnostics,
                    modifier = Modifier.weight(1f).fillMaxHeight(),
                )
            }
        }
    }

    if (showHelp) {
        HelpDialog(
            canOpenDebug = BuildConfig.DEBUG,
            hasTrustedPc = hasTrustedPc,
            onChangeConnectionSettings = { showHelp = false; onChangeConnectionSettings() },
            onForgetTrustedPc = { showHelp = false; onForgetTrustedPc() },
            onOpenDebug = { showHelp = false; onOpenDebug() },
            onDismiss = { showHelp = false },
        )
    }
}

@Composable
private fun PreviewPane(modifier: Modifier, content: @Composable () -> Unit) {
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        content()
    }
}

@Composable
private fun ProductionGuidePanel(
    state: ProductionUiState,
    host: String,
    port: String,
    token: String,
    formError: String?,
    cameraPermissionPermanentlyDenied: Boolean,
    onHostChange: (String) -> Unit,
    onPortChange: (String) -> Unit,
    onTokenChange: (String) -> Unit,
    onConnect: () -> Unit,
    onRequestCameraPermission: () -> Unit,
    onOpenSystemSettings: () -> Unit,
    onRetryCamera: () -> Unit,
    onCancelConnection: () -> Unit,
    onDisconnect: () -> Unit,
    onRetryNow: () -> Unit,
    onChangeConnectionSettings: () -> Unit,
    onShowHelp: () -> Unit,
    onOpenDebug: () -> Unit,
    onExitDebug: () -> Unit,
    onOpenDebugSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
    modifier: Modifier,
) {
    Surface(modifier = modifier, tonalElevation = 4.dp) {
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        stageTitle(state),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.testTag("production_title"),
                    )
                    Text(
                        stageMessage(state),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TextButton(onClick = onShowHelp) { Text("設定・ヘルプ") }
            }

            when (state.stage()) {
                ProductionStage.CAMERA_PERMISSION -> {
                    Text("映像自体はPCへ送信せず、端末内で手と位置合わせマーカーを解析します。")
                    Button(
                        onClick = if (cameraPermissionPermanentlyDenied) {
                            onOpenSystemSettings
                        } else {
                            onRequestCameraPermission
                        },
                        modifier = Modifier.fillMaxWidth().height(52.dp),
                    ) {
                        Text(if (cameraPermissionPermanentlyDenied) "設定を開く" else "カメラを許可")
                    }
                }
                ProductionStage.CAMERA_ERROR -> {
                    Button(onClick = onRetryCamera, modifier = Modifier.fillMaxWidth()) {
                        Text("カメラを再起動")
                    }
                }
                ProductionStage.CONNECT, ProductionStage.CONNECTION_ERROR -> {
                    OutlinedTextField(
                        value = host,
                        onValueChange = onHostChange,
                        label = { Text("PCのIPまたはホスト名") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedTextField(
                            value = port,
                            onValueChange = onPortChange,
                            label = { Text("ポート") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        OutlinedTextField(
                            value = token,
                            onValueChange = onTokenChange,
                            label = { Text("6桁コード") },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    if (!formError.isNullOrBlank()) {
                        Text(formError, color = MaterialTheme.colorScheme.error)
                    }
                    Button(
                        onClick = onConnect,
                        modifier = Modifier.fillMaxWidth().height(52.dp).testTag("connect_button"),
                    ) { Text("接続する") }
                }
                ProductionStage.CONNECTING, ProductionStage.AUTO_CONNECTING -> {
                    Text("接続先  $host:$port")
                    OutlinedButton(onClick = onCancelConnection, modifier = Modifier.fillMaxWidth()) {
                        Text("キャンセル")
                    }
                    if (state.stage() == ProductionStage.AUTO_CONNECTING) {
                        TextButton(
                            onClick = onChangeConnectionSettings,
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("接続先を変更") }
                    }
                }
                ProductionStage.RECONNECTING -> {
                    Text("PCへ座標は送信されていません。カメラ解析は継続しています。")
                    Button(onClick = onRetryNow, modifier = Modifier.fillMaxWidth()) {
                        Text("今すぐ再接続")
                    }
                    OutlinedButton(onClick = onChangeConnectionSettings, modifier = Modifier.fillMaxWidth()) {
                        Text("接続設定を変更")
                    }
                }
                ProductionStage.CALIBRATION -> CalibrationProgress(state.calibration)
                ProductionStage.READY -> {
                    OutlinedButton(onClick = onDisconnect, modifier = Modifier.fillMaxWidth()) {
                        Text("PCから切断")
                    }
                }
            }
            if (state.notice != null) Text(state.notice)
            if (BuildConfig.DEBUG && state.experience == ExperienceMode.DEBUG) {
                Text("DEBUG・最大2手の全骨格を表示中", fontWeight = FontWeight.SemiBold)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    OutlinedButton(onClick = onOpenDebugSettings, modifier = Modifier.weight(1f)) {
                        Text("詳細設定")
                    }
                    OutlinedButton(onClick = onOpenDiagnostics, modifier = Modifier.weight(1f)) {
                        Text("診断")
                    }
                }
                TextButton(onClick = onExitDebug, modifier = Modifier.align(Alignment.End)) {
                    Text("本番モードへ戻る")
                }
            }
            if (BuildConfig.DEBUG && state.experience == ExperienceMode.PRODUCTION) {
                TextButton(onClick = onOpenDebug, modifier = Modifier.align(Alignment.End)) {
                    Text("デバッグへ戻る")
                }
            }
        }
    }
}

@Composable
private fun CalibrationProgress(state: CalibrationUiState) {
    when (state) {
        CalibrationUiState.PlacementWaiting ->
            Text("PC画面全体が映る位置に固定し、PCで「配置OK」を押してください。")
        is CalibrationUiState.FindingMarkers -> Text("検出済み ${state.found}/4")
        is CalibrationUiState.Stabilizing -> {
            Text("安定度 ${state.current}/${state.required}")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                repeat(state.required) { index ->
                    Surface(
                        modifier = Modifier.width(32.dp).height(8.dp),
                        color = if (index < state.current) Color.White else Color.DarkGray,
                        shape = RoundedCornerShape(50),
                    ) {}
                }
            }
        }
        is CalibrationUiState.RetryRequired -> Text(calibrationRetryMessage(state.reason))
        CalibrationUiState.WaitingForPc -> Text("端末を動かさず、そのままお待ちください。")
        CalibrationUiState.Complete -> Text("位置合わせが完了しました。")
        CalibrationUiState.Inactive -> Text("PCからの位置合わせ開始を待っています。")
    }
}

private fun stageTitle(state: ProductionUiState): String = when (state.stage()) {
    ProductionStage.CAMERA_PERMISSION -> "手の動きを読み取るためにカメラを使います"
    ProductionStage.CAMERA_ERROR -> "カメラを起動できません"
    ProductionStage.CONNECT -> "PCに接続"
    ProductionStage.CONNECTING -> "PCに接続しています"
    ProductionStage.AUTO_CONNECTING -> "前回のPCに接続しています"
    ProductionStage.CONNECTION_ERROR -> connectionErrorTitle(state.connection.errorCode)
    ProductionStage.RECONNECTING -> "${state.connection.retryInSeconds ?: 0}秒後に再接続します"
    ProductionStage.CALIBRATION -> when (state.calibration) {
        CalibrationUiState.PlacementWaiting -> "スマホを固定してください"
        is CalibrationUiState.FindingMarkers -> "4つのマーカーを映してください"
        is CalibrationUiState.Stabilizing -> "そのまま動かさないでください"
        CalibrationUiState.WaitingForPc, CalibrationUiState.Complete -> "PCで位置を確認しています"
        is CalibrationUiState.RetryRequired -> "位置合わせをやり直します"
        CalibrationUiState.Inactive -> "PC画面全体をカメラに入れてください"
    }
    ProductionStage.READY -> when (state.tracking) {
        TrackingUiState.CANDIDATE -> "手を確認しています"
        TrackingUiState.TRACKING -> "手を検出しています"
        TrackingUiState.TEMPORARILY_LOST -> "手を見失いました"
        TrackingUiState.LONG_LOST -> "手が見つかりません"
        else -> "操作できます"
    }
}

private fun stageMessage(state: ProductionUiState): String = when (state.stage()) {
    ProductionStage.CAMERA_PERMISSION -> "背面カメラで手とPC画面のマーカーを検出します。"
    ProductionStage.CAMERA_ERROR -> "ほかのアプリがカメラを使用していないか確認してください。"
    ProductionStage.CONNECT -> "接続情報はPCアプリに表示されています。"
    ProductionStage.CONNECTING -> "通常は5秒以内に応答します。"
    ProductionStage.AUTO_CONNECTING -> "保存済みの信頼済み接続情報を使用しています。"
    ProductionStage.CONNECTION_ERROR -> connectionErrorMessage(state.connection.errorCode)
    ProductionStage.RECONNECTING -> "PCとの接続が切れました。"
    ProductionStage.CALIBRATION -> "PC画面の4隅がすべて映るように端末を固定してください。"
    ProductionStage.READY -> when (state.tracking) {
        TrackingUiState.TEMPORARILY_LOST, TrackingUiState.LONG_LOST ->
            "カメラの範囲に手を戻し、照明と距離を確認してください。"
        TrackingUiState.TRACKING -> "PCに接続済みです。"
        else -> "カメラの前に手を映してください。"
    }
}

private fun connectionErrorTitle(code: ConnectionErrorCode?): String = when (code) {
    ConnectionErrorCode.PAIRING_CODE_MISMATCH -> "6桁コードが一致しません"
    ConnectionErrorCode.UNSUPPORTED_VERSION -> "PCアプリを更新してください"
    ConnectionErrorCode.SERVER_BUSY -> "PCが処理中です"
    ConnectionErrorCode.ACK_TIMEOUT -> "PCから応答がありません"
    else -> "PCが見つかりません"
}

private fun connectionErrorMessage(code: ConnectionErrorCode?): String = when (code) {
    ConnectionErrorCode.PAIRING_CODE_MISMATCH -> "PCに表示されたコードを入力し直してください。"
    ConnectionErrorCode.UNSUPPORTED_VERSION -> "Androidアプリと互換性のあるPCアプリが必要です。"
    ConnectionErrorCode.SERVER_BUSY -> "しばらく待ってから、もう一度接続してください。"
    ConnectionErrorCode.ACK_TIMEOUT -> "PCアプリが起動しているか確認してください。"
    else -> "同じネットワーク、IP、ポートを確認してください。"
}

private fun calibrationRetryMessage(reason: CalibrationRetryReason): String = when (reason) {
    CalibrationRetryReason.MARKERS_NOT_VISIBLE -> "4つのマーカーをすべて画面内に入れてください。"
    CalibrationRetryReason.INVALID_GEOMETRY -> "PC画面を正面から映し、四隅の配置を確認してください。"
    CalibrationRetryReason.UNSTABLE -> "端末を固定し、揺れが収まるまで待ってください。"
    CalibrationRetryReason.SCREEN_MISMATCH -> "操作対象のPC画面を映しているか確認してください。"
    CalibrationRetryReason.INTERNAL_ERROR -> "PC側で処理できませんでした。もう一度お試しください。"
    CalibrationRetryReason.UNKNOWN -> "画面全体、照明、端末位置を確認してください。"
}

@Composable
private fun HelpDialog(
    canOpenDebug: Boolean,
    hasTrustedPc: Boolean,
    onChangeConnectionSettings: () -> Unit,
    onForgetTrustedPc: () -> Unit,
    onOpenDebug: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("設定・ヘルプ") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("設置方法", fontWeight = FontWeight.Bold)
                Text("PC画面全体が映る位置へ端末を固定し、反射や逆光を避けてください。")
                Text("プライバシー", fontWeight = FontWeight.Bold)
                Text("カメラ映像は端末内で解析され、PCへは手とマーカーの座標だけを送信します。")
                OutlinedButton(onClick = onChangeConnectionSettings, modifier = Modifier.fillMaxWidth()) {
                    Text("接続先を変更")
                }
                if (hasTrustedPc) {
                    OutlinedButton(onClick = onForgetTrustedPc, modifier = Modifier.fillMaxWidth()) {
                        Text("このPCを忘れる")
                    }
                }
                Text("アプリバージョン ${BuildConfig.VERSION_NAME}")
                if (canOpenDebug) {
                    OutlinedButton(onClick = onOpenDebug, modifier = Modifier.fillMaxWidth()) {
                        Text("デバッグ画面を開く")
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("閉じる") } },
    )
}

data class StateLabSample(val label: String, val state: ProductionUiState)

fun productionStateLabSamples(): List<StateLabSample> {
    val connected = ConnectionSnapshot(ConnectionStatus.CONNECTED, sessionId = "debug-session")
    fun base() = ProductionUiState(camera = CameraUiState.READY, connection = connected)
    return listOf(
        StateLabSample("権限", ProductionUiState(camera = CameraUiState.PERMISSION_REQUIRED)),
        StateLabSample("カメラ異常", ProductionUiState(camera = CameraUiState.ERROR)),
        StateLabSample("接続", ProductionUiState(camera = CameraUiState.READY)),
        StateLabSample("接続中", ProductionUiState(CameraUiState.READY, ConnectionSnapshot(ConnectionStatus.CONNECTING))),
        StateLabSample(
            "自動接続中",
            ProductionUiState(
                CameraUiState.READY,
                ConnectionSnapshot(ConnectionStatus.CONNECTING, automatic = true),
            ),
        ),
        StateLabSample(
            "コード不一致",
            ProductionUiState(
                CameraUiState.READY,
                ConnectionSnapshot(ConnectionStatus.ERROR, errorCode = ConnectionErrorCode.PAIRING_CODE_MISMATCH),
            ),
        ),
        StateLabSample(
            "再接続",
            ProductionUiState(
                CameraUiState.READY,
                ConnectionSnapshot(ConnectionStatus.RECONNECTING, retryInSeconds = 3),
            ),
        ),
        StateLabSample("配置待ち", base().copy(captureMode = CaptureMode.CALIBRATION, calibration = CalibrationUiState.PlacementWaiting)),
        StateLabSample("マーカー探索", base().copy(captureMode = CaptureMode.CALIBRATION, calibration = CalibrationUiState.FindingMarkers(0))),
        StateLabSample("マーカー2/4", base().copy(captureMode = CaptureMode.CALIBRATION, calibration = CalibrationUiState.FindingMarkers(2))),
        StateLabSample("安定3/5", base().copy(captureMode = CaptureMode.CALIBRATION, calibration = CalibrationUiState.Stabilizing(3, 5))),
        StateLabSample("PC確認中", base().copy(captureMode = CaptureMode.CALIBRATION, calibration = CalibrationUiState.WaitingForPc)),
        StateLabSample("再試行", base().copy(captureMode = CaptureMode.CALIBRATION, calibration = CalibrationUiState.RetryRequired(CalibrationRetryReason.INVALID_GEOMETRY))),
        StateLabSample("追跡開始", base().copy(tracking = TrackingUiState.READY_NO_HAND)),
        StateLabSample("取得中", base().copy(tracking = TrackingUiState.CANDIDATE)),
        StateLabSample("追跡中", base().copy(tracking = TrackingUiState.TRACKING)),
        StateLabSample("一時喪失", base().copy(tracking = TrackingUiState.TEMPORARILY_LOST)),
        StateLabSample("長時間喪失", base().copy(tracking = TrackingUiState.LONG_LOST)),
    )
}

@Composable
fun ProductionStateLab(onDismiss: () -> Unit) {
    val samples = remember { productionStateLabSamples() }
    var selected by remember { mutableStateOf(samples.first()) }
    var lastAction by remember { mutableStateOf("操作待ち") }
    Dialog(onDismissRequest = onDismiss) {
        Card(Modifier.fillMaxSize().padding(8.dp)) {
            Column(Modifier.fillMaxSize().padding(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("本番状態ラボ", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                    TextButton(onClick = onDismiss) { Text("閉じる") }
                }
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(samples) { sample ->
                        FilterChip(
                            selected = sample == selected,
                            onClick = { selected = sample; lastAction = "${sample.label}を表示" },
                            label = { Text(sample.label) },
                        )
                    }
                }
                Text(lastAction, style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.height(4.dp))
                ProductionScreen(
                    state = selected.state,
                    savedHost = "127.0.0.1",
                    savedPort = 8080,
                    hasTrustedPc = true,
                    cameraPermissionPermanentlyDenied = false,
                    previewContent = {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text("状態ラボ用プレビュー", color = Color.LightGray)
                        }
                    },
                    onRequestCameraPermission = { lastAction = "カメラ許可" },
                    onOpenSystemSettings = { lastAction = "Android設定" },
                    onRetryCamera = { lastAction = "カメラ再起動" },
                    onConnect = { _, _, _ -> lastAction = "接続"; null },
                    onCancelConnection = { lastAction = "キャンセル" },
                    onDisconnect = { lastAction = "切断" },
                    onRetryNow = { lastAction = "今すぐ再接続" },
                    onChangeConnectionSettings = { lastAction = "接続設定変更" },
                    onForgetTrustedPc = { lastAction = "このPCを忘れる" },
                    onOpenDebug = { lastAction = "デバッグへ戻る" },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}
