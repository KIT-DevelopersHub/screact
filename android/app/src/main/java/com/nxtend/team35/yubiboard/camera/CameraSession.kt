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

    /** 現在のレンズ向き。既定は従来どおり背面。 */
    @Volatile
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK

    /** 直近のバインドで使ったプロファイル群。レンズ切替時に同じ解像度で再バインドするため保持する。 */
    private var lastProfiles: List<CameraProfile> = listOf(CameraProfile.HD_720)

    /** 現在前面カメラを使っているか（UIの表示反映用）。 */
    val isFrontFacing: Boolean
        get() = lensFacing == CameraSelector.LENS_FACING_FRONT

    fun setFrameConsumer(consumer: (ImageProxy) -> Unit) {
        frameConsumer = consumer
    }

    private fun selectorFor(facing: Int): CameraSelector =
        CameraSelector.Builder().requireLensFacing(facing).build()

    /**
     * 前面/背面を切り替えて再バインドする。
     * 反対側のカメラが無い端末では現状を維持し false を返す。
     */
    fun toggleLensFacing(): Boolean {
        val target = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        return setLensFacing(target)
    }

    /**
     * レンズ向きを指定して再バインドする。未起動時は向きだけ記録し、次回 start で反映する。
     * 指定レンズが無ければ現状維持で false を返す。
     */
    fun setLensFacing(facing: Int): Boolean {
        if (facing == lensFacing) return true
        val current = provider ?: run {
            lensFacing = facing
            return true
        }
        val available = runCatching { current.hasCamera(selectorFor(facing)) }.getOrDefault(false)
        if (!available) {
            AppDiagnostics.event("camera", "lens_unavailable", mapOf("facing" to facing))
            return false
        }
        lensFacing = facing
        AppDiagnostics.event("camera", "lens_switched", mapOf("facing" to facing))
        runCatching { bindFirstSupported(current, lastProfiles) }.onFailure(::reportError)
        return true
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
        lastProfiles = profiles
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
            selectorFor(lensFacing),
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

    /**
     * カメラのバインドだけを解除する（executor は生かす）。QR スキャナ等が同じ背面カメラを
     * 使う間、メインプレビューを一時停止するために使う。再開は [start] で再バインドする。
     */
    fun stop() {
        provider?.unbindAll()
    }

    override fun close() {
        provider?.unbindAll()
        analysisExecutor.shutdownNow()
    }
}
