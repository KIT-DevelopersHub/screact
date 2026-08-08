package com.nxtend.team35.yubiboard

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.Size
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import com.nxtend.team35.yubiboard.camera.CameraSession
import com.nxtend.team35.yubiboard.camera.CameraProfile
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import com.nxtend.team35.yubiboard.network.ConnectionSnapshot
import com.nxtend.team35.yubiboard.network.ConnectionStatus
import com.nxtend.team35.yubiboard.protocol.CaptureMode
import com.nxtend.team35.yubiboard.settings.AppSettings
import com.nxtend.team35.yubiboard.vision.ArucoMarkerProcessor
import com.nxtend.team35.yubiboard.vision.DebugOverlayView
import com.nxtend.team35.yubiboard.vision.HandLandmarkerProcessor
import com.nxtend.team35.yubiboard.vision.ProductionOverlayView
import com.nxtend.team35.yubiboard.ui.CameraUiState
import com.nxtend.team35.yubiboard.ui.ExperienceMode
import com.nxtend.team35.yubiboard.ui.ProductionScreen
import com.nxtend.team35.yubiboard.ui.ProductionUiState
import com.nxtend.team35.yubiboard.ui.ProductionStateLab

class MainActivity : ComponentActivity() {
    private lateinit var cameraSession: CameraSession
    private lateinit var handLandmarkerProcessor: HandLandmarkerProcessor
    private lateinit var arucoMarkerProcessor: ArucoMarkerProcessor
    private lateinit var viewModel: MainViewModel
    private lateinit var previewView: PreviewView
    private lateinit var debugOverlay: DebugOverlayView
    private lateinit var productionOverlay: ProductionOverlayView
    private lateinit var connectivityManager: ConnectivityManager
    @Volatile
    private var defaultNetwork: Network? = null
    private var networkCallbackRegistered = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            defaultNetwork = network
            AppDiagnostics.event("network", "android_default_network_available")
            if (::viewModel.isInitialized) viewModel.onNetworkAvailable()
        }

        override fun onLost(network: Network) {
            if (defaultNetwork != network) return
            defaultNetwork = null
            AppDiagnostics.event("network", "android_default_network_lost")
            if (::viewModel.isInitialized) viewModel.onNetworkLost()
        }
    }

    private var cameraStatus by mutableStateOf("カメラを起動中")
    private var cameraPermissionGranted by mutableStateOf(false)
    private var cameraPermissionPermanentlyDenied by mutableStateOf(false)
    private var cameraStarted = false
    private var transientMessage by mutableStateOf<String?>(null)
    @Volatile
    private var currentMode: CaptureMode = CaptureMode.TRACKING

    private val diagnosticsExportLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/x-ndjson"),
    ) { uri ->
        if (uri != null) {
            runCatching {
                contentResolver.openOutputStream(uri)?.bufferedWriter()?.use {
                    it.write(AppDiagnostics.jsonLines())
                }
            }.onFailure {
                AppDiagnostics.event("ui", "diagnostics_export_error", mapOf("message" to it.message))
                transientMessage = "診断ログを保存できませんでした"
            }
        }
    }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        cameraPermissionGranted = granted
        cameraPermissionPermanentlyDenied = !granted && !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)
        if (granted) {
            startCamera()
        } else {
            cameraStatus = "カメラ権限が必要です"
            viewModel.updateCameraState(
                if (cameraPermissionPermanentlyDenied) CameraUiState.PERMISSION_DENIED else CameraUiState.PERMISSION_REQUIRED,
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        viewModel = ViewModelProvider(this)[MainViewModel::class.java]
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        runCatching {
            connectivityManager.registerDefaultNetworkCallback(networkCallback)
            networkCallbackRegistered = true
        }.onFailure {
            AppDiagnostics.event(
                "network",
                "network_callback_registration_failed",
                mapOf("message" to it.message),
            )
        }
        previewView = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FIT_CENTER
            contentDescription = "背面カメラのプレビュー"
        }
        debugOverlay = DebugOverlayView(this)
        productionOverlay = ProductionOverlayView(this)

        val initialSettings = viewModel.currentSettings
        handLandmarkerProcessor = createHandProcessor(initialSettings)
        arucoMarkerProcessor = ArucoMarkerProcessor(
            onResult = { result ->
                viewModel.submitCalibration(result)
                runOnUiThread {
                    debugOverlay.setMarkerResult(result)
                    productionOverlay.setMarkerResult(result)
                    cameraStatus = if (result.stable) {
                        "マーカー ${result.markers.size}/4・安定"
                    } else {
                        "マーカー ${result.markers.size}/4・安定待ち " +
                            "${result.stableFrameCount}/${result.requiredStableFrames}"
                    }
                }
            },
            onError = {
                runOnUiThread { cameraStatus = "ArUco検出を初期化できません" }
            },
        )
        cameraSession = CameraSession(
            context = this,
            lifecycleOwner = this,
            previewView = previewView,
            onReady = {
                cameraStarted = true
                cameraStatus = "カメラ準備完了"
                viewModel.updateCameraState(CameraUiState.READY)
            },
            onError = {
                cameraStatus = "カメラを起動できません"
                cameraStarted = false
                viewModel.updateCameraState(CameraUiState.ERROR)
            },
            onFrameInfo = { info ->
                AppDiagnostics.event(
                    "camera",
                    "production_frame_info",
                    mapOf("actual" to "${info.actualWidth}x${info.actualHeight}"),
                )
            },
        )
        cameraSession.setFrameConsumer { image ->
            if (currentMode == CaptureMode.CALIBRATION) {
                arucoMarkerProcessor.process(image)
            } else {
                handLandmarkerProcessor.process(image)
            }
        }

        viewModel.mode.observe(this) { mode -> currentMode = mode }
        viewModel.calibrationReset.observe(this) {
            arucoMarkerProcessor.reset()
            productionOverlay.clear()
        }
        viewModel.log.observe(this) { message ->
            if (!message.isNullOrBlank()) transientMessage = message
        }

        AppDiagnostics.event(
            "app",
            "created",
            mapOf(
                "model" to android.os.Build.MODEL,
                "android" to android.os.Build.VERSION.RELEASE,
                "sdk" to android.os.Build.VERSION.SDK_INT,
                "version" to BuildConfig.VERSION_NAME,
            ),
        )

        setContent {
            YubiBoardTheme {
                val connection by viewModel.connection.observeAsState(
                    ConnectionSnapshot(ConnectionStatus.DISCONNECTED),
                )
                val mode by viewModel.mode.observeAsState(CaptureMode.TRACKING)
                val settings by viewModel.settings.observeAsState(initialSettings)
                val productionState by viewModel.productionState.observeAsState(ProductionUiState())
                if (settings.debugModeEnabled && BuildConfig.DEBUG) {
                    YubiBoardScreen(
                        previewView = previewView,
                        debugOverlay = debugOverlay,
                        cameraStatus = cameraStatus,
                        cameraPermissionGranted = cameraPermissionGranted,
                        connection = connection,
                        mode = mode,
                        settings = settings,
                        savedHost = viewModel.savedHost,
                        savedPort = viewModel.savedPort,
                        transientMessage = transientMessage,
                        onRequestCameraPermission = {
                            permissionLauncher.launch(Manifest.permission.CAMERA)
                        },
                        onConnect = { host, port, token ->
                            transientMessage = null
                            viewModel.connect(host, port, token).also { error ->
                                if (error != null) transientMessage = error
                            }
                        },
                        onDisconnect = viewModel::disconnect,
                        onModeChange = viewModel::setModeManually,
                        onApplySettings = ::applySettings,
                        onFakeHand = viewModel::submitDebugHand,
                        onFakeMarkers = viewModel::submitDebugCalibration,
                        onClearDiagnostics = AppDiagnostics::clear,
                        onExportDiagnostics = {
                            diagnosticsExportLauncher.launch("yubiboard-diagnostics.jsonl")
                        },
                    )
                } else {
                    ProductionScreen(
                        state = productionState,
                        savedHost = viewModel.savedHost,
                        savedPort = viewModel.savedPort,
                        hasTrustedPc = viewModel.hasTrustedPc,
                        cameraPermissionPermanentlyDenied = cameraPermissionPermanentlyDenied,
                        previewContent = {
                            Box(Modifier.fillMaxSize()) {
                                AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
                                AndroidView(factory = { productionOverlay }, modifier = Modifier.fillMaxSize())
                            }
                        },
                        onRequestCameraPermission = {
                            permissionLauncher.launch(Manifest.permission.CAMERA)
                        },
                        onOpenSystemSettings = ::openAppSettings,
                        onRetryCamera = ::startCamera,
                        onConnect = viewModel::connect,
                        onStartAutoPairing = viewModel::startAutoPairing,
                        onCancelAutoPairing = viewModel::cancelAutoPairing,
                        onCancelConnection = viewModel::disconnect,
                        onDisconnect = viewModel::disconnect,
                        onRetryNow = viewModel::retryNow,
                        onChangeConnectionSettings = viewModel::changeConnectionSettings,
                        onForgetTrustedPc = viewModel::forgetTrustedPc,
                        onOpenDebug = { viewModel.setExperienceMode(ExperienceMode.DEBUG) },
                    )
                }
            }
        }

        cameraPermissionGranted = hasCameraPermission()
        if (cameraPermissionGranted) {
            startCamera()
        } else {
            cameraStatus = "カメラ権限が必要です"
            viewModel.updateCameraState(CameraUiState.PERMISSION_REQUIRED)
        }
    }

    override fun onResume() {
        super.onResume()
        val granted = hasCameraPermission()
        if (granted && !cameraPermissionGranted) {
            cameraPermissionGranted = true
            cameraPermissionPermanentlyDenied = false
            startCamera()
        }
    }

    override fun onDestroy() {
        if (networkCallbackRegistered) {
            runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            networkCallbackRegistered = false
        }
        cameraSession.close()
        handLandmarkerProcessor.close()
        super.onDestroy()
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun startCamera() {
        if (!hasCameraPermission()) {
            viewModel.updateCameraState(CameraUiState.PERMISSION_REQUIRED)
            return
        }
        cameraStatus = "手を探索中"
        cameraStarted = false
        viewModel.updateCameraState(CameraUiState.STARTING)
        val settings = viewModel.currentSettings
        val profile = if (settings.debugModeEnabled && BuildConfig.DEBUG) {
            CameraProfile.from(Size(settings.analysisWidth, settings.analysisHeight))
        } else {
            CameraProfile.HD_720
        }
        cameraSession.start(profile, allowFallback = !profile.debugOnly)
    }

    private fun openAppSettings() {
        startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            ),
        )
    }

    private fun createHandProcessor(settings: AppSettings) = HandLandmarkerProcessor(
        context = this,
        minDetectionConfidence = settings.minDetectionConfidence,
        minPresenceConfidence = settings.minPresenceConfidence,
        minTrackingConfidence = settings.minTrackingConfidence,
        onResult = { result ->
            viewModel.submitHand(result)
            runOnUiThread {
                debugOverlay.setHandResult(result)
                productionOverlay.setHandResult(result)
                cameraStatus = if (result.detected) {
                    "手を検出・%.1f fps・%d ms".format(result.framesPerSecond, result.inferenceTimeMs)
                } else {
                    "手を検出できません・%.1f fps".format(result.framesPerSecond)
                }
            }
        },
        onError = {
            runOnUiThread { cameraStatus = "手検知を初期化できません" }
        },
    )

    private fun applySettings(candidate: AppSettings): String? {
        val previous = viewModel.currentSettings
        val error = viewModel.updateSettings(candidate)
        if (error != null) return error
        val detectorChanged = previous.minDetectionConfidence != candidate.minDetectionConfidence ||
            previous.minPresenceConfidence != candidate.minPresenceConfidence ||
            previous.minTrackingConfidence != candidate.minTrackingConfidence
        if (detectorChanged) replaceHandProcessor(candidate)
        if (cameraPermissionGranted &&
            (previous.analysisWidth != candidate.analysisWidth ||
                previous.analysisHeight != candidate.analysisHeight ||
                previous.debugModeEnabled != candidate.debugModeEnabled)
        ) {
            startCamera()
        }
        transientMessage = if (candidate.debugModeEnabled) {
            "デバッグモードを有効にしました"
        } else {
            "本番モードを有効にしました"
        }
        return null
    }

    private fun replaceHandProcessor(settings: AppSettings) {
        val previous = handLandmarkerProcessor
        handLandmarkerProcessor = createHandProcessor(settings)
        previewView.postDelayed({ previous.close() }, PROCESSOR_CLOSE_DELAY_MS)
    }

    companion object {
        private const val PROCESSOR_CLOSE_DELAY_MS = 1_000L
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun YubiBoardScreen(
    previewView: PreviewView,
    debugOverlay: DebugOverlayView,
    cameraStatus: String,
    cameraPermissionGranted: Boolean,
    connection: ConnectionSnapshot,
    mode: CaptureMode,
    settings: AppSettings,
    savedHost: String,
    savedPort: Int,
    transientMessage: String?,
    onRequestCameraPermission: () -> Unit,
    onConnect: (String, String, String) -> String?,
    onDisconnect: () -> Unit,
    onModeChange: (CaptureMode) -> Unit,
    onApplySettings: (AppSettings) -> String?,
    onFakeHand: (Boolean) -> Unit,
    onFakeMarkers: () -> Unit,
    onClearDiagnostics: () -> Unit,
    onExportDiagnostics: () -> Unit,
) {
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var showDiagnostics by rememberSaveable { mutableStateOf(false) }
    var showStateLab by rememberSaveable { mutableStateOf(false) }
    var host by rememberSaveable { mutableStateOf(savedHost.ifBlank { "127.0.0.1" }) }
    var port by rememberSaveable { mutableStateOf(savedPort.toString()) }
    var token by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(settings.debugModeEnabled) {
        if (!settings.debugModeEnabled) showDiagnostics = false
    }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
        AndroidView(factory = { debugOverlay }, modifier = Modifier.fillMaxSize())

        FlowRow(
            modifier = Modifier.safeDrawingPadding().padding(12.dp).fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusChip(cameraStatus, Color(0xCC142B31))
            StatusChip(connectionLabel(connection), connectionColor(connection.status))
            StatusChip(
                if (mode == CaptureMode.CALIBRATION) "位置合わせ" else "手を追跡",
                Color(0xCC4A3B16),
            )
            if (settings.debugModeEnabled) StatusChip("DEBUG", Color(0xCCD04A36))
        }

        ConnectionPanel(
            modifier = Modifier.align(Alignment.BottomCenter),
            connection = connection,
            mode = mode,
            host = host,
            port = port,
            token = token,
            debugModeEnabled = settings.debugModeEnabled,
            transientMessage = transientMessage,
            onHostChange = { host = it },
            onPortChange = { port = it.filter(Char::isDigit).take(5) },
            onTokenChange = { token = it.filter(Char::isDigit).take(6) },
            onConnect = { onConnect(host, port, token) },
            onDisconnect = onDisconnect,
            onModeChange = onModeChange,
            onOpenSettings = { showSettings = true },
            onOpenDiagnostics = { showDiagnostics = true },
        )

        if (!cameraPermissionGranted) {
            CameraPermissionCard(
                modifier = Modifier.align(Alignment.Center),
                onRequestPermission = onRequestCameraPermission,
            )
        }
    }

    if (showSettings) {
        SettingsDialog(
            settings = settings,
            onDismiss = { showSettings = false },
            onApply = { candidate ->
                onApplySettings(candidate).also { if (it == null) showSettings = false }
            },
        )
    }
    if (showDiagnostics && settings.debugModeEnabled) {
        DiagnosticsDialog(
            onDismiss = { showDiagnostics = false },
            onFakeHand = onFakeHand,
            onFakeMarkers = onFakeMarkers,
            onClear = onClearDiagnostics,
            onExport = onExportDiagnostics,
            onOpenStateLab = { showDiagnostics = false; showStateLab = true },
        )
    }
    if (showStateLab && settings.debugModeEnabled) {
        ProductionStateLab(onDismiss = { showStateLab = false })
    }
}

@Composable
private fun StatusChip(text: String, background: Color) {
    Surface(color = background, shape = RoundedCornerShape(50), tonalElevation = 4.dp) {
        Text(
            text = text,
            color = Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 7.dp),
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ConnectionPanel(
    modifier: Modifier,
    connection: ConnectionSnapshot,
    mode: CaptureMode,
    host: String,
    port: String,
    token: String,
    debugModeEnabled: Boolean,
    transientMessage: String?,
    onHostChange: (String) -> Unit,
    onPortChange: (String) -> Unit,
    onTokenChange: (String) -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onModeChange: (CaptureMode) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDiagnostics: () -> Unit,
) {
    val connectedOrBusy = connection.status !in setOf(ConnectionStatus.DISCONNECTED, ConnectionStatus.ERROR)
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        shadowElevation = 16.dp,
    ) {
        Column(
            modifier = Modifier
                .safeDrawingPadding()
                .heightIn(max = 430.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("PC接続", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(
                        connectionLabel(connection),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TextButton(onClick = onOpenSettings) { Text("設定") }
                if (debugModeEnabled) {
                    TextButton(onClick = onOpenDiagnostics) { Text("診断") }
                }
            }

            if (!connectedOrBusy) {
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
                Button(onClick = onConnect, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                    Text("PCへ接続")
                }
            } else {
                Text(
                    "接続先  $host:$port",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedButton(onClick = onDisconnect, modifier = Modifier.fillMaxWidth()) {
                    Text("接続を切断")
                }
            }

            Button(
                onClick = {
                    onModeChange(
                        if (mode == CaptureMode.CALIBRATION) CaptureMode.TRACKING else CaptureMode.CALIBRATION,
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (mode == CaptureMode.CALIBRATION) "手の追跡へ戻る" else "位置合わせを開始")
            }
            if (!transientMessage.isNullOrBlank()) {
                Text(
                    transientMessage,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.tertiary,
                )
            }
        }
    }
}

@Composable
private fun CameraPermissionCard(modifier: Modifier, onRequestPermission: () -> Unit) {
    Card(
        modifier = modifier.padding(24.dp).fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("カメラの許可が必要です", style = MaterialTheme.typography.titleLarge)
            Text("手と画面マーカーを検出するため、背面カメラへのアクセスを許可してください。")
            Button(onClick = onRequestPermission, modifier = Modifier.fillMaxWidth()) {
                Text("カメラを許可")
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SettingsDialog(
    settings: AppSettings,
    onDismiss: () -> Unit,
    onApply: (AppSettings) -> String?,
) {
    var draft by remember(settings) { mutableStateOf(settings) }
    var detection by remember(settings) { mutableStateOf(settings.minDetectionConfidence.toString()) }
    var presence by remember(settings) { mutableStateOf(settings.minPresenceConfidence.toString()) }
    var tracking by remember(settings) { mutableStateOf(settings.minTrackingConfidence.toString()) }
    var sendFps by remember(settings) { mutableStateOf(settings.maxSendFps.toString()) }
    var error by remember { mutableStateOf<String?>(null) }

    Dialog(onDismissRequest = onDismiss) {
        Card(modifier = Modifier.fillMaxWidth().fillMaxHeight(0.9f)) {
            Column(
                Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text("設定", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Surface(
                    color = if (draft.debugModeEnabled) {
                        MaterialTheme.colorScheme.tertiaryContainer
                    } else {
                        MaterialTheme.colorScheme.surfaceVariant
                    },
                    shape = RoundedCornerShape(18.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth().padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("デバッグモード", fontWeight = FontWeight.SemiBold)
                            Text(
                                if (draft.debugModeEnabled) {
                                    "診断、疑似入力、詳細設定を表示します"
                                } else {
                                    "操作に必要な項目だけを表示します"
                                },
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        Switch(
                            checked = draft.debugModeEnabled,
                            onCheckedChange = { draft = draft.copy(debugModeEnabled = it) },
                        )
                    }
                }

                Text("解析解像度", fontWeight = FontWeight.SemiBold)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = draft.analysisWidth == 1280,
                        onClick = { draft = draft.copy(analysisWidth = 1280, analysisHeight = 720) },
                        label = { Text("1280 × 720") },
                    )
                    FilterChip(
                        selected = draft.analysisWidth == 640,
                        onClick = { draft = draft.copy(analysisWidth = 640, analysisHeight = 480) },
                        label = { Text("640 × 480") },
                    )
                    FilterChip(
                        selected = draft.analysisWidth == 960,
                        onClick = { draft = draft.copy(analysisWidth = 960, analysisHeight = 540) },
                        label = { Text("960 × 540") },
                    )
                    FilterChip(
                        selected = draft.analysisWidth == 1920,
                        onClick = { draft = draft.copy(analysisWidth = 1920, analysisHeight = 1080) },
                        label = { Text("1920 × 1080（比較用）") },
                    )
                }

                OutlinedTextField(
                    value = sendFps,
                    onValueChange = { sendFps = it.filter(Char::isDigit).take(2) },
                    label = { Text("最大送信fps（5〜20）") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                if (draft.debugModeEnabled) {
                    Text("検出しきい値", fontWeight = FontWeight.SemiBold)
                    ConfidenceField("検出信頼度", detection) { detection = it }
                    ConfidenceField("存在信頼度", presence) { presence = it }
                    ConfidenceField("追跡信頼度", tracking) { tracking = it }
                }

                if (error != null) {
                    Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = onDismiss) { Text("キャンセル") }
                    Spacer(Modifier.width(8.dp))
                    Button(onClick = {
                        val candidate = draft.copy(
                            minDetectionConfidence = detection.toFloatOrNull() ?: Float.NaN,
                            minPresenceConfidence = presence.toFloatOrNull() ?: Float.NaN,
                            minTrackingConfidence = tracking.toFloatOrNull() ?: Float.NaN,
                            maxSendFps = sendFps.toIntOrNull() ?: -1,
                        )
                        error = onApply(candidate)
                    }) { Text("適用") }
                }
            }
        }
    }
}

@Composable
private fun ConfidenceField(label: String, value: String, onValueChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = { onValueChange(it.filter { char -> char.isDigit() || char == '.' }.take(4)) },
        label = { Text("$label（0.0〜1.0）") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DiagnosticsDialog(
    onDismiss: () -> Unit,
    onFakeHand: (Boolean) -> Unit,
    onFakeMarkers: () -> Unit,
    onClear: () -> Unit,
    onExport: () -> Unit,
    onOpenStateLab: () -> Unit,
) {
    var output by remember { mutableStateOf(AppDiagnostics.format()) }
    fun refresh() { output = AppDiagnostics.format() }
    Dialog(onDismissRequest = onDismiss) {
        Card(modifier = Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
            Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("デバッグ診断", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    OutlinedButton(onClick = { refresh() }) { Text("更新") }
                    OutlinedButton(onClick = { onClear(); refresh() }) { Text("消去") }
                    OutlinedButton(onClick = onExport) { Text("JSONL保存") }
                    OutlinedButton(onClick = onOpenStateLab) { Text("本番状態ラボ") }
                }
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Button(onClick = { onFakeHand(true); refresh() }) { Text("疑似21点") }
                    Button(onClick = { onFakeHand(false); refresh() }) { Text("疑似未検出") }
                    Button(onClick = { onFakeMarkers(); refresh() }) { Text("疑似4マーカー") }
                }
                Surface(
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    color = Color(0xFF0D171A),
                    shape = RoundedCornerShape(12.dp),
                ) {
                    SelectionContainer {
                        Text(
                            output,
                            modifier = Modifier.verticalScroll(rememberScrollState()).padding(12.dp),
                            color = Color(0xFFD7F7ED),
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                        )
                    }
                }
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) {
                    Text("閉じる")
                }
            }
        }
    }
}

private fun connectionLabel(snapshot: ConnectionSnapshot): String = when (snapshot.status) {
    ConnectionStatus.DISCONNECTED -> "未接続"
    ConnectionStatus.CONNECTING -> "接続中"
    ConnectionStatus.AWAITING_ACK -> "PC応答待ち"
    ConnectionStatus.CONNECTED -> "接続済み"
    ConnectionStatus.RECONNECTING -> snapshot.retryInSeconds?.let { "${it}秒後に再接続" }
        ?: "再接続中"
    ConnectionStatus.ERROR -> snapshot.detail ?: "接続エラー"
}

private fun connectionColor(status: ConnectionStatus): Color = when (status) {
    ConnectionStatus.CONNECTED -> Color(0xCC176B52)
    ConnectionStatus.CONNECTING, ConnectionStatus.AWAITING_ACK, ConnectionStatus.RECONNECTING ->
        Color(0xCC8A5D14)
    ConnectionStatus.ERROR -> Color(0xCC9D352F)
    ConnectionStatus.DISCONNECTED -> Color(0xCC37474F)
}

private val YubiBoardColors = darkColorScheme(
    primary = Color(0xFFF1F1F1),
    onPrimary = Color(0xFF181818),
    secondary = Color(0xFFCECECE),
    tertiary = Color(0xFFBDBDBD),
    background = Color(0xFF101010),
    surface = Color(0xFF1B1B1B),
    surfaceVariant = Color(0xFF303030),
)

@Composable
private fun YubiBoardTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = YubiBoardColors, content = content)
}
