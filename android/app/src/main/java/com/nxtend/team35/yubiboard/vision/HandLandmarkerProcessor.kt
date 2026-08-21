package com.nxtend.team35.yubiboard.vision

import android.content.Context
import android.os.SystemClock
import androidx.camera.core.ImageProxy
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.nxtend.team35.yubiboard.camera.toCorrectedBitmap
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap

class HandLandmarkerProcessor(
    context: Context,
    private val trackAssigner: HandTrackAssigner,
    private val onResult: (HandDetectionResult) -> Unit,
    private val onError: (Throwable) -> Unit,
    maxHands: Int = 1,
    minDetectionConfidence: Float = DEFAULT_CONFIDENCE,
    minPresenceConfidence: Float = DEFAULT_CONFIDENCE,
    minTrackingConfidence: Float = DEFAULT_CONFIDENCE,
) : AutoCloseable {
    private var handLandmarker: HandLandmarker? = null
    private val frameTimes = ArrayDeque<Long>()
    private val trackingStateMachine = TrackingStateMachine()
    private val pendingMirrorByTimestamp = ConcurrentHashMap<Long, Boolean>()

    init {
        require(maxHands in 1..HandTrackAssigner.MAX_HANDS)
        runCatching {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(MODEL_FILE)
                .build()
            val options = HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(baseOptions)
                .setMinHandDetectionConfidence(minDetectionConfidence)
                .setMinHandPresenceConfidence(minPresenceConfidence)
                .setMinTrackingConfidence(minTrackingConfidence)
                .setNumHands(maxHands)
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setResultListener(::handleResult)
                .setErrorListener(onError)
                .build()
            handLandmarker = HandLandmarker.createFromOptions(context, options)
        }.onFailure(onError)
    }

    fun process(image: ImageProxy, mirror: Boolean = false) {
        val detector = handLandmarker
        if (detector == null) {
            image.close()
            return
        }

        val capturedAt = SystemClock.uptimeMillis()
        AppDiagnostics.increment("hand.frames_submitted")
        // MediaPipeには鏡像化していない画像を渡す。撮影時のレンズ状態を時刻へ
        // 紐付け、非同期結果の座標だけをミラープレビュー座標へ反転する。
        val correctedBitmap = image.toCorrectedBitmap()
        val mpImage = BitmapImageBuilder(correctedBitmap).build()
        pendingMirrorByTimestamp[capturedAt] = mirror
        runCatching { detector.detectAsync(mpImage, capturedAt) }
            .onFailure {
                pendingMirrorByTimestamp.remove(capturedAt)
                onError(it)
            }
    }

    private fun handleResult(result: HandLandmarkerResult, input: com.google.mediapipe.framework.image.MPImage) {
        val now = SystemClock.uptimeMillis()
        frameTimes.addLast(now)
        while (frameTimes.isNotEmpty() && frameTimes.first() < now - FPS_WINDOW_MS) {
            frameTimes.removeFirst()
        }

        val mirror = pendingMirrorByTimestamp.remove(result.timestampMs()) ?: run {
            AppDiagnostics.event(
                "vision",
                "hand_result_context_missing",
                mapOf("timestampMs" to result.timestampMs()),
            )
            return
        }
        val candidates = result.landmarks().mapIndexedNotNull { index, rawLandmarks ->
            val landmarks = rawLandmarks.map { point ->
                LandmarkPoint(point.x(), point.y(), point.z())
            }
            if (landmarks.size != HAND_LANDMARK_COUNT ||
                landmarks.any { !it.x.isFinite() || !it.y.isFinite() || !it.z.isFinite() }
            ) {
                null
            } else {
                val category = result.handedness().getOrNull(index)?.firstOrNull()
                val candidate = HandCandidate(
                    landmarks = landmarks,
                    handedness = category?.categoryName()?.uppercase(),
                    handednessScore = category?.score(),
                )
                if (mirror) candidate.mirrorHorizontally() else candidate
            }
        }
        val hands = trackAssigner.assign(candidates, result.timestampMs())
        val detected = hands.isNotEmpty()
        AppDiagnostics.increment("hand.results")
        if (detected) AppDiagnostics.increment("hand.detected") else AppDiagnostics.increment("hand.missing")
        AppDiagnostics.gauge("hand.fps", frameTimes.size * 1000f / FPS_WINDOW_MS)
        AppDiagnostics.gauge("hand.inference_ms", (now - result.timestampMs()).coerceAtLeast(0))
        AppDiagnostics.metric("hand.fps", frameTimes.size * 1000f / FPS_WINDOW_MS)
        AppDiagnostics.metric("hand.inference_ms", (now - result.timestampMs()).coerceAtLeast(0))
        val trackingState = trackingStateMachine.update(detected, result.timestampMs())
        AppDiagnostics.gauge("hand.tracking_state", trackingState)
        AppDiagnostics.sampled(
            key = "hand_result",
            category = "vision",
            name = "hand_result",
            fields = mapOf(
                "detected" to detected,
                "handCount" to hands.size,
                "trackIds" to hands.joinToString(",") { it.trackId.toString() },
                "fps" to frameTimes.size * 1000f / FPS_WINDOW_MS,
                "inferenceMs" to (now - result.timestampMs()).coerceAtLeast(0),
                "trackingState" to trackingState,
                "mirrored" to mirror,
                "indexTips" to hands.joinToString("|") { hand ->
                    hand.landmarks.getOrNull(8)?.let { "${hand.trackId}:${it.x},${it.y},${it.z}" }.orEmpty()
                },
            ),
        )
        onResult(
            HandDetectionResult(
                capturedAtMonotonicMs = result.timestampMs(),
                sourceWidth = input.width,
                sourceHeight = input.height,
                hands = hands,
                trackingState = trackingState,
                inferenceTimeMs = (now - result.timestampMs()).coerceAtLeast(0),
                framesPerSecond = frameTimes.size * 1000f / FPS_WINDOW_MS,
                cameraFacing = if (mirror) "front" else "back",
            ),
        )
    }

    override fun close() {
        handLandmarker?.close()
        handLandmarker = null
        pendingMirrorByTimestamp.clear()
    }

    companion object {
        private const val MODEL_FILE = "hand_landmarker.task"
        private const val DEFAULT_CONFIDENCE = 0.5f
        private const val HAND_LANDMARK_COUNT = 21
        private const val FPS_WINDOW_MS = 1_000L
    }
}
