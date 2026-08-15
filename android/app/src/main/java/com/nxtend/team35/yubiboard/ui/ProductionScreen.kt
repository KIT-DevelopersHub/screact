package com.nxtend.team35.yubiboard.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.nxtend.team35.yubiboard.BuildConfig
import com.nxtend.team35.yubiboard.R
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
    maxHands: Int = 1,
    cameraPermissionPermanentlyDenied: Boolean,
    previewContent: @Composable () -> Unit,
    onRequestCameraPermission: () -> Unit,
    onOpenSystemSettings: () -> Unit,
    onRetryCamera: () -> Unit,
    onConnect: (String, String, String) -> String?,
    onStartAutoPairing: () -> Unit,
    onCancelAutoPairing: () -> Unit,
    onCancelConnection: () -> Unit,
    onDisconnect: () -> Unit,
    onRetryNow: () -> Unit,
    onChangeConnectionSettings: () -> Unit,
    onForgetTrustedPc: () -> Unit,
    onMaxHandsChange: (Int) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    var host by rememberSaveable { mutableStateOf(savedHost.ifBlank { "127.0.0.1" }) }
    var port by rememberSaveable { mutableStateOf(savedPort.toString()) }
    var token by rememberSaveable { mutableStateOf("") }
    var formError by remember { mutableStateOf<String?>(null) }
    var showHelp by rememberSaveable { mutableStateOf(false) }
    // 手動接続（IP・6桁コード入力）はブロードキャスト不達環境向けの逃げ道。
    var showManual by rememberSaveable { mutableStateOf(false) }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(Color(0xFFD8D8D8)),
    ) {
        val portrait = maxHeight >= maxWidth
        if (portrait) {
            Column(Modifier.fillMaxSize()) {
                PreviewPane(Modifier.fillMaxWidth().weight(0.85f), previewContent)
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
                    showManual = showManual,
                    onStartAutoPairing = { formError = null; onStartAutoPairing() },
                    onCancelAutoPairing = onCancelAutoPairing,
                    onShowManual = {
                        onCancelAutoPairing()
                        formError = null
                        showManual = true
                    },
                    onHideManual = { formError = null; showManual = false },
                    onRequestCameraPermission = onRequestCameraPermission,
                    onOpenSystemSettings = onOpenSystemSettings,
                    onRetryCamera = onRetryCamera,
                    onCancelConnection = onCancelConnection,
                    onDisconnect = onDisconnect,
                    onRetryNow = onRetryNow,
                    onChangeConnectionSettings = onChangeConnectionSettings,
                    onShowHelp = { showHelp = true },
                    modifier = Modifier.fillMaxWidth().weight(1.15f),
                )
            }
        } else {
            Row(Modifier.fillMaxSize()) {
                PreviewPane(Modifier.weight(2.1f).fillMaxHeight(), previewContent)
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
                    showManual = showManual,
                    onStartAutoPairing = { formError = null; onStartAutoPairing() },
                    onCancelAutoPairing = onCancelAutoPairing,
                    onShowManual = {
                        onCancelAutoPairing()
                        formError = null
                        showManual = true
                    },
                    onHideManual = { formError = null; showManual = false },
                    onRequestCameraPermission = onRequestCameraPermission,
                    onOpenSystemSettings = onOpenSystemSettings,
                    onRetryCamera = onRetryCamera,
                    onCancelConnection = onCancelConnection,
                    onDisconnect = onDisconnect,
                    onRetryNow = onRetryNow,
                    onChangeConnectionSettings = onChangeConnectionSettings,
                    onShowHelp = { showHelp = true },
                    modifier = Modifier.weight(1f).fillMaxHeight(),
                )
            }
        }
    }

    if (showHelp) {
        HelpDialog(
            hasTrustedPc = hasTrustedPc,
            isConnected = state.connection.status == ConnectionStatus.CONNECTED,
            maxHands = maxHands,
            onMaxHandsChange = onMaxHandsChange,
            onChangeConnectionSettings = { showHelp = false; onChangeConnectionSettings() },
            onDisconnect = { showHelp = false; onDisconnect() },
            onForgetTrustedPc = { showHelp = false; onForgetTrustedPc() },
            onDismiss = { showHelp = false },
        )
    }
}

@Composable
private fun PreviewPane(modifier: Modifier, content: @Composable () -> Unit) {
    Box(
        modifier.background(Color(0xFFD8D8D8)).testTag("production_camera_preview"),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

private val GuideInk = Color(0xFF4A4A4A)
private val GuideBodyInk = Color(0xFF686666)
private val GuideButton = Color(0xFF686666)
private val GuideField = Color(0xFFFFFDFD)
private val GuideError = Color(0xFF9B3E3A)

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
    showManual: Boolean,
    onStartAutoPairing: () -> Unit,
    onCancelAutoPairing: () -> Unit,
    onShowManual: () -> Unit,
    onHideManual: () -> Unit,
    onRequestCameraPermission: () -> Unit,
    onOpenSystemSettings: () -> Unit,
    onRetryCamera: () -> Unit,
    onCancelConnection: () -> Unit,
    onDisconnect: () -> Unit,
    onRetryNow: () -> Unit,
    onChangeConnectionSettings: () -> Unit,
    onShowHelp: () -> Unit,
    modifier: Modifier,
) {
    BoxWithConstraints(modifier = modifier.background(Color.White)) {
        // Phone landscape content is only about 400dp tall after system insets. Use the
        // compact measurements before applying those insets so every state fits without scroll.
        val compact = maxHeight < 520.dp
        val narrow = maxWidth < 220.dp
        val horizontalPadding = when {
            narrow -> 12.dp
            compact -> 14.dp
            else -> 30.dp
        }
        val verticalPadding = if (compact) 6.dp else 22.dp

        Image(
            painter = painterResource(R.drawable.production_watercolor_background),
            contentDescription = null,
            contentScale = ContentScale.FillBounds,
            modifier = Modifier.fillMaxSize(),
        )

        Box(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(
                    WindowInsets.safeDrawing.only(
                        WindowInsetsSides.Vertical + WindowInsetsSides.End,
                    ),
                ),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag("production_guide_viewport"),
            ) {
                Column(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .fillMaxWidth()
                        .padding(horizontal = horizontalPadding, vertical = verticalPadding)
                        .testTag("production_guide_content"),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    when (state.visualState()) {
                        ProductionVisualState.CAMERA_PERMISSION -> CameraPermissionPanel(
                            state = state,
                            cameraPermissionPermanentlyDenied = cameraPermissionPermanentlyDenied,
                            onRequestCameraPermission = onRequestCameraPermission,
                            onOpenSystemSettings = onOpenSystemSettings,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.CAMERA_ERROR -> CameraErrorPanel(
                            state = state,
                            onRetryCamera = onRetryCamera,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.CONNECTION_FORM -> {
                            if (showManual) {
                                ConnectionFormPanel(
                                    state = state,
                                    host = host,
                                    port = port,
                                    token = token,
                                    formError = formError,
                                    onHostChange = onHostChange,
                                    onPortChange = onPortChange,
                                    onTokenChange = onTokenChange,
                                    onConnect = onConnect,
                                    onHideManual = onHideManual,
                                    compact = compact,
                                    narrow = narrow,
                                )
                            } else {
                                AutoPairingStartPanel(
                                    state = state,
                                    onStartAutoPairing = onStartAutoPairing,
                                    onShowManual = onShowManual,
                                    compact = compact,
                                    narrow = narrow,
                                )
                            }
                        }
                        ProductionVisualState.DISCOVERY_WAITING -> DiscoveryWaitingPanel(
                            state = state,
                            onCancelAutoPairing = onCancelAutoPairing,
                            onShowManual = onShowManual,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.CONNECTION_PROGRESS -> ConnectionProgressPanel(
                            state = state,
                            host = host,
                            port = port,
                            onCancelConnection = onCancelConnection,
                            onChangeConnectionSettings = onChangeConnectionSettings,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.RECONNECTING -> ReconnectingPanel(
                            state = state,
                            onRetryNow = onRetryNow,
                            onChangeConnectionSettings = onChangeConnectionSettings,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.PLACEMENT -> PlacementPanel(
                            state = state,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.CALIBRATION_PROGRESS -> CalibrationPanel(
                            state = state,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.READY_IDLE -> ReadyPanel(
                            state = state,
                            onDisconnect = onDisconnect,
                            showActions = false,
                            compact = compact,
                            narrow = narrow,
                        )
                        ProductionVisualState.READY_ACTIVE -> ReadyPanel(
                            state = state,
                            onDisconnect = onDisconnect,
                            showActions = true,
                            compact = compact,
                            narrow = narrow,
                        )
                    }

                    state.notice?.takeIf(String::isNotBlank)?.let { notice ->
                        Spacer(Modifier.height(if (compact) 6.dp else 12.dp))
                        GuideFeedback(notice, compact = compact)
                    }
                }
                if (state.visualState() == ProductionVisualState.PLACEMENT) {
                    GuideCharacter(
                        compact = compact,
                        sizeOverride = if (compact) 68.dp else 112.dp,
                        modifier = Modifier.align(Alignment.BottomEnd),
                    )
                }

                GuideHelpButton(
                    onClick = onShowHelp,
                    modifier = Modifier.align(Alignment.TopEnd).padding(8.dp),
                )
            }
        }
    }
}

@Composable
private fun CameraPermissionPanel(
    state: ProductionUiState,
    cameraPermissionPermanentlyDenied: Boolean,
    onRequestCameraPermission: () -> Unit,
    onOpenSystemSettings: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        compactFontSize = 22.sp,
        compactLineHeight = 26.sp,
        modifier = Modifier.fillMaxWidth(if (compact) 0.90f else 0.86f),
    )
    GuideCharacter(
        compact = compact,
        sizeOverride = if (compact) 64.dp else 126.dp,
    )
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 10.dp else 18.dp))
    GuideSecondaryText(
        "映像はPCへ送信せず、端末内で解析します。",
        compact = compact,
        narrow = narrow,
    )
    Spacer(Modifier.height(if (compact) 12.dp else 22.dp))
    GuideFilledButton(
        text = if (cameraPermissionPermanentlyDenied) "設定を開く" else "カメラを許可",
        onClick = if (cameraPermissionPermanentlyDenied) {
            onOpenSystemSettings
        } else {
            onRequestCameraPermission
        },
        compact = compact,
    )
}

@Composable
private fun CameraErrorPanel(
    state: ProductionUiState,
    onRetryCamera: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        modifier = Modifier.fillMaxWidth(if (compact) 0.76f else 0.86f),
    )
    GuideCharacter(compact = compact)
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 16.dp else 28.dp))
    GuideFilledButton("カメラを再起動", onRetryCamera, compact = compact)
}

@Composable
private fun AutoPairingStartPanel(
    state: ProductionUiState,
    onStartAutoPairing: () -> Unit,
    onShowManual: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        // 実機の横向きスマホでは案内パネルが約300dp幅になる。ここだけは
        // 1文字が次行へ孤立しない大きさに抑え、見出しを中央1行に収める。
        compactFontSize = 21.sp,
        compactLineHeight = 25.sp,
        modifier = Modifier.fillMaxWidth(if (compact) 1f else 0.86f),
    )
    GuideCharacter(
        compact = compact,
        sizeOverride = if (compact) 68.dp else 116.dp,
    )
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 12.dp else 22.dp))
    GuideFilledButton(
        text = "画面認識開始",
        onClick = onStartAutoPairing,
        compact = compact,
        tag = "auto_pair_button",
    )
    TextButton(
        onClick = onShowManual,
        modifier = Modifier.testTag("show_manual_connection"),
    ) {
        Text(
            text = "手動で接続する（IP・6桁コード）",
            color = GuideBodyInk,
            fontSize = if (compact) 12.sp else 15.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun DiscoveryWaitingPanel(
    state: ProductionUiState,
    onCancelAutoPairing: () -> Unit,
    onShowManual: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        compactFontSize = 24.sp,
        compactLineHeight = 28.sp,
        modifier = Modifier.fillMaxWidth(if (compact) 0.92f else 0.86f),
    )
    GuideCharacter(
        compact = compact,
        sizeOverride = if (compact) 62.dp else 108.dp,
    )
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 9.dp else 16.dp))
    LinearProgressIndicator(
        color = GuideInk,
        trackColor = Color.White.copy(alpha = 0.64f),
        modifier = Modifier
            .fillMaxWidth(if (compact) 0.76f else 0.70f)
            .height(4.dp)
            .testTag("pairing_progress"),
    )
    Spacer(Modifier.height(if (compact) 11.dp else 20.dp))
    GuideOutlinedButton(
        text = "キャンセル",
        onClick = onCancelAutoPairing,
        compact = compact,
        tag = "cancel_pairing_button",
    )
    TextButton(
        onClick = onShowManual,
        modifier = Modifier.testTag("show_manual_connection"),
    ) {
        Text(
            text = "手動で接続する（IP・6桁コード）",
            color = GuideBodyInk,
            fontSize = if (compact) 12.sp else 15.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun ConnectionFormPanel(
    state: ProductionUiState,
    host: String,
    port: String,
    token: String,
    formError: String?,
    onHostChange: (String) -> Unit,
    onPortChange: (String) -> Unit,
    onTokenChange: (String) -> Unit,
    onConnect: () -> Unit,
    onHideManual: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    val spacing = if (compact) 5.dp else 12.dp
    val connectionError = state.stage() == ProductionStage.CONNECTION_ERROR
    val visibleFormError = formError?.takeIf(String::isNotBlank)
    Box(
        modifier = Modifier.fillMaxWidth(if (compact) 0.96f else 0.84f),
        contentAlignment = Alignment.Center,
    ) {
        GuideCharacter(
            compact = true,
            sizeOverride = if (narrow) 40.dp else 46.dp,
            modifier = Modifier.align(Alignment.CenterStart),
        )
        GuideTitle(
            "PCに接続",
            compact = compact,
            narrow = narrow,
            compactFontSize = 24.sp,
            compactLineHeight = 28.sp,
            maxLines = 1,
            modifier = Modifier.fillMaxWidth().testTag("production_title"),
        )
    }
    Spacer(Modifier.height(spacing))
    if (connectionError) {
        GuideFeedback(
            "${connectionErrorTitle(state.connection.errorCode)}。${connectionErrorMessage(state.connection.errorCode)}",
            compact = compact,
        )
        Spacer(Modifier.height(spacing))
    } else if (visibleFormError != null) {
        GuideFeedback(visibleFormError, compact = compact)
        Spacer(Modifier.height(spacing))
    } else {
        GuideBody(
            "接続情報はPCアプリに\n表示されています！",
            compact = compact,
            narrow = narrow,
        )
        Spacer(Modifier.height(spacing))
    }

    ConnectionField(
        label = "PCのIPアドレスまたはホスト名入力",
        value = host,
        onValueChange = onHostChange,
        keyboardType = KeyboardType.Uri,
        tag = "host_field",
        compact = compact,
        narrow = narrow,
        modifier = Modifier.fillMaxWidth(if (compact) 0.96f else 0.84f),
    )
    Spacer(Modifier.height(spacing))
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(if (narrow) 8.dp else 12.dp),
    ) {
        ConnectionField(
            label = "ポート入力",
            value = port,
            onValueChange = onPortChange,
            keyboardType = KeyboardType.Number,
            tag = "port_field",
            compact = compact,
            narrow = narrow,
            modifier = Modifier.weight(1f),
        )
        ConnectionField(
            label = "6桁コード入力",
            value = token,
            onValueChange = onTokenChange,
            keyboardType = KeyboardType.NumberPassword,
            tag = "pairing_code_field",
            compact = compact,
            narrow = narrow,
            modifier = Modifier.weight(1f),
        )
    }
    Spacer(Modifier.height(if (compact) 9.dp else 22.dp))
    GuideFilledButton(
        text = "接続",
        onClick = onConnect,
        compact = compact,
        tag = "connect_button",
        widthFraction = if (compact) 0.66f else 0.60f,
    )
    TextButton(
        onClick = onHideManual,
        modifier = Modifier.testTag("hide_manual_connection"),
    ) {
        Text(
            text = "自動検出に戻る",
            color = GuideBodyInk,
            fontSize = if (compact) 12.sp else 15.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun ConnectionProgressPanel(
    state: ProductionUiState,
    host: String,
    port: String,
    onCancelConnection: () -> Unit,
    onChangeConnectionSettings: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        modifier = Modifier.fillMaxWidth(if (compact) 0.82f else 0.90f),
    )
    GuideCharacter(compact = compact)
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 8.dp else 14.dp))
    GuideSecondaryText("接続先  $host:$port", compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 14.dp else 24.dp))
    GuideOutlinedButton("キャンセル", onCancelConnection, compact = compact)
    if (state.stage() == ProductionStage.AUTO_CONNECTING) {
        Spacer(Modifier.height(if (compact) 9.dp else 14.dp))
        GuideFilledButton("接続先を変更", onChangeConnectionSettings, compact = compact)
    }
}

@Composable
private fun ReconnectingPanel(
    state: ProductionUiState,
    onRetryNow: () -> Unit,
    onChangeConnectionSettings: () -> Unit,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        modifier = Modifier.fillMaxWidth(if (compact) 0.78f else 0.86f),
    )
    Spacer(Modifier.height(if (compact) 10.dp else 18.dp))
    GuideBody("PCとの接続が途切れました。", compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 10.dp else 18.dp))
    GuideSecondaryText(
        "PCへの座標は送信されていません。\nカメラ解析は継続しています。",
        compact = compact,
        narrow = narrow,
    )
    Spacer(Modifier.height(if (compact) 20.dp else 34.dp))
    GuideOutlinedButton(
        "今すぐ再接続",
        onRetryNow,
        compact = compact,
        tag = "reconnect_now_button",
    )
    Spacer(Modifier.height(if (compact) 9.dp else 14.dp))
    GuideFilledButton(
        "接続設定を変更",
        onChangeConnectionSettings,
        compact = compact,
        tag = "reconnect_settings_button",
    )
    Spacer(Modifier.height(if (compact) 3.dp else 8.dp))
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(if (compact) 48.dp else 82.dp),
    ) {
        GuideCharacter(
            compact = compact,
            sizeOverride = if (compact) 62.dp else 105.dp,
            modifier = Modifier.align(Alignment.BottomStart),
        )
    }
}

@Composable
private fun PlacementPanel(
    state: ProductionUiState,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        modifier = Modifier.fillMaxWidth(if (compact) 0.76f else 0.86f),
    )
    Spacer(Modifier.height(if (compact) 16.dp else 28.dp))
    GuideBody(
        "PC画面の4隅がすべて映るように\n端末を固定してください。",
        compact = compact,
        narrow = narrow,
    )
    Spacer(Modifier.height(if (compact) 14.dp else 24.dp))
    GuideSecondaryText(
        "PC画面全体が映る位置に固定し、\nPCで「配置OK」を\n押してください。",
        compact = compact,
        narrow = narrow,
    )
}

@Composable
private fun CalibrationPanel(
    state: ProductionUiState,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(stageTitle(state), compact = compact, narrow = narrow)
    Spacer(Modifier.height(if (compact) 8.dp else 14.dp))
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    GuideCharacter(
        compact = compact,
        sizeOverride = if (compact) 76.dp else 120.dp,
    )
    CalibrationProgress(state.calibration, compact = compact, narrow = narrow)
}

@Composable
private fun ReadyPanel(
    state: ProductionUiState,
    onDisconnect: () -> Unit,
    showActions: Boolean,
    compact: Boolean,
    narrow: Boolean,
) {
    GuideTitle(
        stageTitle(state),
        compact = compact,
        narrow = narrow,
        modifier = Modifier.fillMaxWidth(
            if (compact && showActions) 0.72f else 1f,
        ),
    )
    GuideCharacter(
        compact = compact,
        sizeOverride = when {
            compact && showActions -> 68.dp
            compact -> 80.dp
            showActions -> 110.dp
            else -> 126.dp
        },
    )
    GuideBody(stageMessage(state), compact = compact, narrow = narrow)
    if (showActions) {
        Spacer(Modifier.height(if (compact) 14.dp else 28.dp))
        GuideOutlinedButton("PCから切断", onDisconnect, compact = compact)
    } else {
        Spacer(Modifier.height(if (compact) 116.dp else 160.dp))
    }
}

@Composable
private fun CalibrationProgress(
    state: CalibrationUiState,
    compact: Boolean,
    narrow: Boolean,
) {
    when (state) {
        CalibrationUiState.PlacementWaiting -> GuideSecondaryText(
            "PC画面全体が映る位置に固定し、PCで「配置OK」を押してください。",
            compact = compact,
            narrow = narrow,
        )
        is CalibrationUiState.FindingMarkers -> GuideSecondaryText(
            "検出済み ${state.found}/4",
            compact = compact,
            narrow = narrow,
        )
        is CalibrationUiState.Stabilizing -> {
            GuideSecondaryText(
                "安定度 ${state.current}/${state.required}",
                compact = compact,
                narrow = narrow,
            )
            Spacer(Modifier.height(if (compact) 7.dp else 10.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
            ) {
                repeat(state.required.coerceAtMost(12)) { index ->
                    Surface(
                        modifier = Modifier.weight(1f).height(if (compact) 7.dp else 9.dp),
                        color = if (index < state.current) GuideInk else Color(0xFFD2D2D2),
                        shape = RoundedCornerShape(50),
                    ) {}
                }
            }
        }
        is CalibrationUiState.RetryRequired -> GuideFeedback(
            calibrationRetryMessage(state.reason),
            compact = compact,
        )
        CalibrationUiState.WaitingForPc -> GuideSecondaryText(
            "端末を動かさず、そのままお待ちください。",
            compact = compact,
            narrow = narrow,
        )
        CalibrationUiState.Complete -> GuideSecondaryText(
            "位置合わせが完了しました。",
            compact = compact,
            narrow = narrow,
        )
        CalibrationUiState.Inactive -> GuideSecondaryText(
            "PCからの位置合わせ開始を待っています。",
            compact = compact,
            narrow = narrow,
        )
    }
}

@Composable
private fun ConnectionField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    keyboardType: KeyboardType,
    tag: String,
    compact: Boolean,
    narrow: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            text = label,
            color = GuideBodyInk,
            fontSize = if (narrow || compact) 11.sp else 15.sp,
            lineHeight = if (narrow || compact) 13.sp else 18.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            textStyle = TextStyle(
                color = GuideInk,
                fontSize = if (compact) 16.sp else 18.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            cursorBrush = SolidColor(GuideInk),
            decorationBox = { innerTextField ->
                Box(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    innerTextField()
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(if (compact) 48.dp else 52.dp)
                .background(GuideField, RoundedCornerShape(if (compact) 12.dp else 16.dp))
                .border(
                    width = 1.5.dp,
                    color = GuideInk,
                    shape = RoundedCornerShape(if (compact) 12.dp else 16.dp),
                )
                .semantics { contentDescription = label }
                .testTag(tag),
        )
    }
}

@Composable
private fun GuideTitle(
    text: String,
    compact: Boolean,
    narrow: Boolean,
    compactFontSize: TextUnit = 28.sp,
    compactLineHeight: TextUnit = 32.sp,
    maxLines: Int = Int.MAX_VALUE,
    modifier: Modifier = Modifier.fillMaxWidth(),
) {
    val fontSize = when {
        narrow -> 25.sp
        compact -> compactFontSize
        else -> 38.sp
    }
    Text(
        text = text,
        color = GuideInk,
        fontSize = fontSize,
        lineHeight = when {
            narrow -> 28.sp
            compact -> compactLineHeight
            else -> 43.sp
        },
        fontWeight = FontWeight.Black,
        textAlign = TextAlign.Center,
        maxLines = maxLines,
        modifier = modifier.testTag("production_title"),
    )
}

@Composable
private fun GuideBody(text: String, compact: Boolean, narrow: Boolean) {
    val fontSize = when {
        narrow -> 13.sp
        compact -> 14.sp
        else -> 20.sp
    }
    Text(
        text = text,
        color = GuideBodyInk,
        fontSize = fontSize,
        lineHeight = when {
            narrow -> 17.sp
            compact -> 18.sp
            else -> 26.sp
        },
        fontWeight = FontWeight.Bold,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun GuideSecondaryText(text: String, compact: Boolean, narrow: Boolean) {
    val fontSize = when {
        narrow -> 12.sp
        compact -> 14.sp
        else -> 17.sp
    }
    Text(
        text = text,
        color = GuideBodyInk,
        fontSize = fontSize,
        lineHeight = when {
            narrow -> 16.sp
            compact -> 18.sp
            else -> 23.sp
        },
        fontWeight = FontWeight.Bold,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun GuideFeedback(text: String, compact: Boolean) {
    Text(
        text = text,
        color = GuideError,
        fontSize = if (compact) 12.sp else 15.sp,
        lineHeight = if (compact) 16.sp else 20.sp,
        fontWeight = FontWeight.Bold,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun GuideCharacter(
    compact: Boolean,
    modifier: Modifier = Modifier,
    sizeOverride: androidx.compose.ui.unit.Dp? = null,
) {
    val width = sizeOverride ?: if (compact) 80.dp else 126.dp
    Image(
        painter = painterResource(R.drawable.production_character),
        contentDescription = "ゆびボードのキャラクター",
        // The supplied square PNG has transparent space above and below the artwork. Cropping
        // only that empty area keeps the character's visible size while avoiding wasted height.
        contentScale = ContentScale.Crop,
        modifier = modifier
            .size(width = width, height = width * 0.75f)
            .testTag("production_character"),
    )
}

@Composable
private fun GuideFilledButton(
    text: String,
    onClick: () -> Unit,
    compact: Boolean,
    tag: String? = null,
    widthFraction: Float = 0.84f,
) {
    Button(
        onClick = onClick,
        shape = RoundedCornerShape(if (compact) 12.dp else 18.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = GuideButton,
            contentColor = Color.White,
        ),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
        modifier = Modifier
            .fillMaxWidth(widthFraction)
            .heightIn(min = if (compact) 44.dp else 56.dp)
            .then(if (tag == null) Modifier else Modifier.testTag(tag)),
    ) {
        Text(
            text = text,
            fontSize = if (compact) 20.sp else 27.sp,
            fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun GuideOutlinedButton(
    text: String,
    onClick: () -> Unit,
    compact: Boolean,
    tag: String? = null,
) {
    OutlinedButton(
        onClick = onClick,
        shape = RoundedCornerShape(if (compact) 12.dp else 18.dp),
        border = BorderStroke(if (compact) 1.5.dp else 2.dp, GuideInk),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = GuideField,
            contentColor = GuideBodyInk,
        ),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
        modifier = Modifier
            .fillMaxWidth(0.84f)
            .heightIn(min = if (compact) 44.dp else 56.dp)
            .then(if (tag == null) Modifier else Modifier.testTag(tag)),
    ) {
        Text(
            text = text,
            fontSize = if (compact) 20.sp else 26.sp,
            fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun GuideHelpButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(48.dp)
            .semantics { contentDescription = "設定・ヘルプ" }
            .clickable(role = Role.Button, onClick = onClick)
            .testTag("production_help_button"),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .background(Color.White.copy(alpha = 0.45f), CircleShape)
                .border(3.dp, GuideInk, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "?",
                color = GuideInk,
                fontSize = 22.sp,
                lineHeight = 22.sp,
                fontWeight = FontWeight.Black,
            )
        }
    }
}

private fun stageTitle(state: ProductionUiState): String = when (state.stage()) {
    ProductionStage.CAMERA_PERMISSION -> "手の動きを読み取るためにカメラを使います"
    ProductionStage.CAMERA_ERROR -> "カメラを起動できません"
    ProductionStage.CONNECT -> "画面認識をはじめましょう"
    ProductionStage.DISCOVERY_WAITING -> "PCからの接続を待っています"
    ProductionStage.CONNECTING -> "PCに接続しています"
    ProductionStage.AUTO_CONNECTING -> "PCに自動接続しています"
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
        else -> "操作できます！"
    }
}

private fun stageMessage(state: ProductionUiState): String = when (state.stage()) {
    ProductionStage.CAMERA_PERMISSION -> "背面カメラで手とPC画面のマーカーを検出します。"
    ProductionStage.CAMERA_ERROR -> "ほかのアプリがカメラを使用していないか確認してください。"
    ProductionStage.CONNECT -> "PC画面全体が映る位置に端末を固定して、ボタンを押してください。"
    ProductionStage.DISCOVERY_WAITING -> "PC側で「スマホ設置完了」を押すと自動で接続されます。"
    ProductionStage.CONNECTING -> "通常は5秒以内に応答します。"
    ProductionStage.AUTO_CONNECTING -> "保存済み、または自動検出した接続情報を使用しています。"
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
    hasTrustedPc: Boolean,
    isConnected: Boolean,
    maxHands: Int,
    onMaxHandsChange: (Int) -> Unit,
    onChangeConnectionSettings: () -> Unit,
    onDisconnect: () -> Unit,
    onForgetTrustedPc: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("設定・ヘルプ") },
        text = {
            Column(
                modifier = Modifier.testTag("production_help_content"),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("操作する手の数", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChip(
                        selected = maxHands == 1,
                        onClick = { onMaxHandsChange(1) },
                        label = { Text("1手のみ") },
                        modifier = Modifier.testTag("hand_mode_single"),
                    )
                    FilterChip(
                        selected = maxHands == 2,
                        onClick = { onMaxHandsChange(2) },
                        label = { Text("2手") },
                        modifier = Modifier.testTag("hand_mode_dual"),
                    )
                }
                Text(
                    if (maxHands == 1) {
                        "認識の安定性と負荷の軽さを優先します。"
                    } else {
                        "2手を同時に検出します。端末負荷が高くなる場合があります。"
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
                Text("設置方法", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Text(
                    "PC画面全体が映る位置へ端末を固定し、反射や逆光を避けてください。",
                    style = MaterialTheme.typography.bodySmall,
                )
                Text("プライバシー", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Text(
                    "カメラ映像は端末内で解析され、PCへは手とマーカーの座標だけを送信します。",
                    style = MaterialTheme.typography.bodySmall,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedButton(
                        onClick = onChangeConnectionSettings,
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        modifier = Modifier.weight(1f).heightIn(min = 40.dp),
                    ) {
                        Text("接続先を変更", maxLines = 1)
                    }
                    if (isConnected) {
                        OutlinedButton(
                            onClick = onDisconnect,
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            modifier = Modifier.weight(1f).heightIn(min = 40.dp),
                        ) {
                            Text("PCから切断", maxLines = 1)
                        }
                    }
                }
                if (hasTrustedPc) {
                    OutlinedButton(
                        onClick = onForgetTrustedPc,
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 40.dp),
                    ) {
                        Text("このPCを忘れる")
                    }
                }
                Text(
                    "アプリバージョン ${BuildConfig.VERSION_NAME}",
                    style = MaterialTheme.typography.bodySmall,
                )
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
        StateLabSample(
            "検出待受",
            ProductionUiState(camera = CameraUiState.READY, pairing = PairingUiState.WAITING),
        ),
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
                    onStartAutoPairing = { lastAction = "画面認識開始" },
                    onCancelAutoPairing = { lastAction = "待受キャンセル" },
                    onCancelConnection = { lastAction = "キャンセル" },
                    onDisconnect = { lastAction = "切断" },
                    onRetryNow = { lastAction = "今すぐ再接続" },
                    onChangeConnectionSettings = { lastAction = "接続設定変更" },
                    onForgetTrustedPc = { lastAction = "このPCを忘れる" },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}
