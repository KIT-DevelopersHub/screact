package com.nxtend.team35.yubiboard.camera

import android.content.Context
import android.util.Size
import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class CameraSession(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val previewView: PreviewView,
    private val onReady: () -> Unit,
    private val onError: (Throwable) -> Unit,
    private val onFrameInfo: (CameraFrameInfo) -> Unit = {},
) : AutoCloseable {
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    @Volatile
    private var frameConsumer: (ImageProxy) -> Unit = { it.close() }

    fun setFrameConsumer(consumer: (ImageProxy) -> Unit) {
        frameConsumer = consumer
    }

    fun start(targetSize: Size) = start(CameraProfile.from(targetSize), allowFallback = true)

    fun start(
        preferredProfile: CameraProfile = CameraProfile.HD_720,
        allowFallback: Boolean = true,
    ) {
        val profiles = if (allowFallback && !preferredProfile.debugOnly) {
            val startIndex = CameraProfile.productionOrder.indexOf(preferredProfile).coerceAtLeast(0)
            CameraProfile.productionOrder.drop(startIndex)
        } else {
            listOf(preferredProfile)
        }
        AppDiagnostics.event(
            "camera",
            "start_requested",
            mapOf("profiles" to profiles.joinToString { "${it.width}x${it.height}" }),
        )
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener(
            {
                runCatching {
                    provider = providerFuture.get()
                    bindFirstSupported(providerFuture.get(), profiles)
                }.onFailure(::reportError)
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    private fun bindFirstSupported(provider: ProcessCameraProvider, profiles: List<CameraProfile>) {
        var lastError: Throwable? = null
        for (profile in profiles) {
            val result = runCatching { bind(provider, profile) }
            if (result.isSuccess) return
            lastError = result.exceptionOrNull()
            AppDiagnostics.event(
                "camera",
                "profile_rejected",
                mapOf(
                    "profile" to "${profile.width}x${profile.height}",
                    "message" to lastError?.message,
                ),
            )
        }
        reportError(lastError ?: IllegalStateException("No camera profile is available"))
    }

    private fun bind(provider: ProcessCameraProvider, profile: CameraProfile) {
        val frameLogged = AtomicBoolean(false)
        val aspectStrategy = if (profile.width * 3 == profile.height * 4) {
            AspectRatioStrategy(
                AspectRatio.RATIO_4_3,
                AspectRatioStrategy.FALLBACK_RULE_AUTO,
            )
        } else {
            AspectRatioStrategy(
                AspectRatio.RATIO_16_9,
                AspectRatioStrategy.FALLBACK_RULE_AUTO,
            )
        }
        val selector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(aspectStrategy)
            .setResolutionStrategy(
                ResolutionStrategy(profile.size, ResolutionStrategy.FALLBACK_RULE_NONE),
            )
            .setAllowedResolutionMode(ResolutionSelector.PREFER_CAPTURE_RATE_OVER_HIGHER_RESOLUTION)
            .build()
        val preview = Preview.Builder()
            .setResolutionSelector(selector)
            .build()
            .also { it.surfaceProvider = previewView.surfaceProvider }
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(selector)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { useCase ->
                useCase.setAnalyzer(analysisExecutor) { image ->
                    if (frameLogged.compareAndSet(false, true)) reportFrameInfo(profile, image)
                    frameConsumer(image)
                }
            }
        val groupBuilder = UseCaseGroup.Builder()
            .addUseCase(preview)
            .addUseCase(analysis)
        previewView.viewPort?.let(groupBuilder::setViewPort)

        provider.unbindAll()
        provider.bindToLifecycle(
            lifecycleOwner,
            CameraSelector.DEFAULT_BACK_CAMERA,
            groupBuilder.build(),
        )
        AppDiagnostics.gauge("camera.requested_resolution", "${profile.width}x${profile.height}")
        AppDiagnostics.event("camera", "ready", mapOf("profile" to profile))
        onReady()
    }

    private fun reportFrameInfo(profile: CameraProfile, image: ImageProxy) {
        val crop = image.cropRect
        val rotation = image.imageInfo.rotationDegrees
        val rotated = rotation == 90 || rotation == 270
        val actualWidth = if (rotated) crop.height() else crop.width()
        val actualHeight = if (rotated) crop.width() else crop.height()
        val info = CameraFrameInfo(
            requestedProfile = profile,
            actualWidth = actualWidth,
            actualHeight = actualHeight,
            rotationDegrees = rotation,
            cropLeft = crop.left,
            cropTop = crop.top,
            cropRight = crop.right,
            cropBottom = crop.bottom,
        )
        AppDiagnostics.gauge("camera.actual_resolution", "${actualWidth}x${actualHeight}")
        AppDiagnostics.event(
            "camera",
            "first_frame",
            mapOf(
                "requested" to "${profile.width}x${profile.height}",
                "actual" to "${actualWidth}x${actualHeight}",
                "rotation" to rotation,
                "cropRect" to "${crop.left},${crop.top},${crop.right},${crop.bottom}",
            ),
        )
        onFrameInfo(info)
    }

    private fun reportError(error: Throwable) {
        AppDiagnostics.event("camera", "error", mapOf("message" to error.message))
        onError(error)
    }

    override fun close() {
        provider?.unbindAll()
        analysisExecutor.shutdownNow()
    }
}
