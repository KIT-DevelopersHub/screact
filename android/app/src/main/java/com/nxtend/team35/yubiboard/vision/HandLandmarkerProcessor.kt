package com.nxtend.team35.yubiboard.vision

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import androidx.camera.core.ImageProxy
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import java.util.ArrayDeque

class HandLandmarkerProcessor(
    context: Context,
    private val onResult: (HandDetectionResult) -> Unit,
    private val onError: (Throwable) -> Unit,
    minDetectionConfidence: Float = DEFAULT_CONFIDENCE,
    minPresenceConfidence: Float = DEFAULT_CONFIDENCE,
    minTrackingConfidence: Float = DEFAULT_CONFIDENCE,
) : AutoCloseable {
    private var handLandmarker: HandLandmarker? = null
    private val frameTimes = ArrayDeque<Long>()

    init {
        runCatching {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(MODEL_FILE)
                .build()
            val options = HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(baseOptions)
                .setMinHandDetectionConfidence(minDetectionConfidence)
                .setMinHandPresenceConfidence(minPresenceConfidence)
                .setMinTrackingConfidence(minTrackingConfidence)
                .setNumHands(1)
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

        val capturedAt = SystemClock.uptimeMillis()
        val rotationDegrees = image.imageInfo.rotationDegrees
        val bitmap = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
        try {
            image.planes[0].buffer.rewind()
            bitmap.copyPixelsFromBuffer(image.planes[0].buffer)
        } finally {
            image.close()
        }

        val correctedBitmap = if (rotationDegrees == 0) {
            bitmap
        } else {
            Bitmap.createBitmap(
                bitmap,
                0,
                0,
                bitmap.width,
                bitmap.height,
                Matrix().apply { postRotate(rotationDegrees.toFloat()) },
                true,
            )
        }
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

        val landmarks = result.landmarks().firstOrNull()?.map { point ->
            LandmarkPoint(point.x(), point.y(), point.z())
        }.orEmpty()
        val category = result.handedness().firstOrNull()?.firstOrNull()
        onResult(
            HandDetectionResult(
                capturedAtMonotonicMs = result.timestampMs(),
                sourceWidth = input.width,
                sourceHeight = input.height,
                detected = landmarks.size == HAND_LANDMARK_COUNT,
                landmarks = landmarks,
                handedness = category?.categoryName()?.uppercase(),
                handednessScore = category?.score(),
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
