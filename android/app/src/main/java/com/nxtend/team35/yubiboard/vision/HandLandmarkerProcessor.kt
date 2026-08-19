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

class HandLandmarkerProcessor(
    context: Context,
    private val trackAssigner: HandTrackAssigner,
    private val onResult: (HandDetectionResult) -> Unit,
    private val onError: (Throwable) -> Unit,
    maxHands: Int = 1,
    minDetectionConfidence: Float = DEFAULT_CONFIDENCE,
    minPresenceConfidence: Float = DEFAULT_CONFIDENCE,
    minTrackingConfidence: Float = DEFAULT_CONFIDENCE,
    // N フレームに1回だけ推論へ投入する（1 = 全フレーム投入＝現状維持）。
    private val inferenceFrameStride: Int = 1,
) : AutoCloseable {
    private var handLandmarker: HandLandmarker? = null
    private val frameTimes = ArrayDeque<Long>()
    private val trackingStateMachine = TrackingStateMachine()
    private var frameCounter = 0L

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

    fun process(image: ImageProxy) {
        val detector = handLandmarker
        if (detector == null) {
            image.close()
            return
        }

        // 間引き: stride>1 のとき、Bitmap生成・推論より手前でフレームを捨てる
        // （変換コストごと削減）。捨てるフレームも ImageProxy は必ず close する。
        val stride = if (inferenceFrameStride < 1) 1 else inferenceFrameStride
        val index = frameCounter++
        if (stride > 1 && index % stride != 0L) {
            AppDiagnostics.increment("hand.frames_skipped")
            image.close()
            return
        }

        val capturedAt = SystemClock.uptimeMillis()
        AppDiagnostics.increment("hand.frames_submitted")
        val correctedBitmap = image.toCorrectedBitmap()
        val mpImage = BitmapImageBuilder(correctedBitmap).build()
        runCatching { detector.detectAsync(mpImage, capturedAt) }
            .onFailure(onError)
    }

    private fun handleResult(result: HandLandmarkerResult, input: com.google.mediapipe.framework.image.MPImage) {
        val now = SystemClock.uptimeMillis()
        frameTimes.addLast(now)
        while (frameTimes.isNotEmpty() && frameTimes.first() < now - FPS_WINDOW_MS) {
            frameTimes.removeFirst()
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
                HandCandidate(
                    landmarks = landmarks,
                    handedness = category?.categoryName()?.uppercase(),
                    handednessScore = category?.score(),
                )
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
            ),
        )
    }

    override fun close() {
        handLandmarker?.close()
        handLandmarker = null
    }

    companion object {
        private const val MODEL_FILE = "hand_landmarker.task"
        private const val DEFAULT_CONFIDENCE = 0.5f
        private const val HAND_LANDMARK_COUNT = 21
        private const val FPS_WINDOW_MS = 1_000L
    }
}
