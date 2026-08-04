package com.nxtend.team35.yubiboard.camera

import android.content.Context
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class CameraSession(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val previewView: PreviewView,
    private val onReady: () -> Unit,
    private val onError: (Throwable) -> Unit,
) : AutoCloseable {
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    @Volatile
    private var frameConsumer: (ImageProxy) -> Unit = { it.close() }

    fun setFrameConsumer(consumer: (ImageProxy) -> Unit) {
        frameConsumer = consumer
    }

    fun start(targetSize: Size = Size(640, 480)) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener(
            {
                runCatching {
                    val provider = providerFuture.get()
                    val preview = Preview.Builder().build().also {
                        it.surfaceProvider = previewView.surfaceProvider
                    }
                    @Suppress("DEPRECATION")
                    val analysis = ImageAnalysis.Builder()
                        .setTargetResolution(targetSize)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                        .also { useCase ->
                            useCase.setAnalyzer(analysisExecutor) { image -> frameConsumer(image) }
                        }

                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )
                    onReady()
                }.onFailure(onError)
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    override fun close() {
        analysisExecutor.shutdownNow()
    }
}
