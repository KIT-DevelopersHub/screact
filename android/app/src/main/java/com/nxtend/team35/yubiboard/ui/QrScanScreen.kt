package com.nxtend.team35.yubiboard.ui

import android.annotation.SuppressLint
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.findViewTreeLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.nxtend.team35.yubiboard.network.PairingPayload
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * QR コード（`screact://pair?...`）をカメラで読み取り、LAN 直結ペイロードを検出したら
 * 一度だけ [onResult] を呼ぶ画面。自前の [ProcessCameraProvider] を持ち、バインド前に
 * unbindAll() でメインプレビューのカメラ使用を解放する（呼び出し側もメインカメラを止める）。
 *
 * ライフサイクル安全：ビューツリーの LifecycleOwner にバインドし、離脱時に unbindAll()、
 * 解析後は必ず ImageProxy を close する。
 *
 * カメラ権限はメインプレビューと同一の許可状態を再利用する前提で、許可済みのときだけ表示する。
 */
@Composable
fun QrScanScreen(
    onResult: (host: String, port: Int, token: String) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val view = LocalView.current
    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }
    // 最新のコールバックを掴む（再構成でラムダが変わっても DisposableEffect を張り直さない）。
    val currentOnResult by rememberUpdatedState(onResult)

    DisposableEffect(Unit) {
        val analysisExecutor = Executors.newSingleThreadExecutor()
        val handled = AtomicBoolean(false)
        val scanner: BarcodeScanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
        var provider: ProcessCameraProvider? = null

        val analyzer = QrAnalyzer(scanner, handled) { host, port, token ->
            // 解析スレッドからメインスレッドへ戻して接続を開始する。
            previewView.post { currentOnResult(host, port, token) }
        }

        val lifecycleOwner = view.findViewTreeLifecycleOwner()
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener(
            {
                val cameraProvider = runCatching { providerFuture.get() }.getOrNull()
                    ?: return@addListener
                provider = cameraProvider
                if (lifecycleOwner == null) return@addListener
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { it.setAnalyzer(analysisExecutor, analyzer) }
                runCatching {
                    // メインカメラが残っていても確実に解放してから QR 用にバインドする。
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                }
            },
            ContextCompat.getMainExecutor(context),
        )

        onDispose {
            runCatching { provider?.unbindAll() }
            runCatching { scanner.close() }
            analysisExecutor.shutdown()
        }
    }

    Box(
        modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        AndroidView(
            factory = { previewView },
            modifier = Modifier.fillMaxSize().testTag("qr_scan_preview"),
        )
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .safeDrawingPadding()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = "PC画面のQRコードをカメラに映してください",
                color = Color.White,
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
            )
            Button(
                onClick = onCancel,
                shape = RoundedCornerShape(16.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.White.copy(alpha = 0.9f),
                    contentColor = Color(0xFF303030),
                ),
                contentPadding = PaddingValues(horizontal = 24.dp, vertical = 12.dp),
                modifier = Modifier.testTag("qr_scan_cancel_button"),
            ) {
                Text("キャンセル", fontWeight = FontWeight.Black, fontSize = 18.sp)
            }
        }
    }
}

/** ML Kit で QR を解析し、LAN 直結ペイロードを一度だけ通知する Analyzer。 */
private class QrAnalyzer(
    private val scanner: BarcodeScanner,
    private val handled: AtomicBoolean,
    private val onLanPayload: (host: String, port: Int, token: String) -> Unit,
) : ImageAnalysis.Analyzer {
    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        if (handled.get()) {
            imageProxy.close()
            return
        }
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }
        val input = InputImage.fromMediaImage(
            mediaImage,
            imageProxy.imageInfo.rotationDegrees,
        )
        scanner.process(input)
            .addOnSuccessListener { barcodes ->
                for (barcode in barcodes) {
                    val raw = barcode.rawValue ?: continue
                    val payload = PairingPayload.tryParse(raw) ?: continue
                    if (!payload.hasLanDirect) continue
                    // 最初の有効ペイロードで確定。以後のフレームは無視する。
                    if (handled.compareAndSet(false, true)) {
                        onLanPayload(payload.lanHost!!, payload.lanPort!!, payload.pairingToken)
                    }
                    break
                }
            }
            .addOnCompleteListener { imageProxy.close() }
    }
}
