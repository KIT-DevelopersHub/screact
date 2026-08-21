package com.nxtend.team35.yubiboard.vision

import android.os.SystemClock
import androidx.camera.core.ImageProxy
import com.nxtend.team35.yubiboard.camera.toCorrectedBitmap
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.imgproc.Imgproc
import org.opencv.objdetect.ArucoDetector
import org.opencv.objdetect.Objdetect

class ArucoMarkerProcessor(
    private val onResult: (MarkerDetectionResult) -> Unit,
    private val onError: (Throwable) -> Unit,
) {
    private val stabilityTracker = MarkerStabilityTracker()
    private val detector: ArucoDetector?

    init {
        detector = runCatching {
            check(OpenCVLoader.initLocal()) { "OpenCV initialization failed" }
            ArucoDetector(Objdetect.getPredefinedDictionary(Objdetect.DICT_4X4_50))
        }.onFailure(onError).getOrNull()
    }

    fun process(image: ImageProxy, mirror: Boolean = false) {
        val activeDetector = detector
        if (activeDetector == null) {
            image.close()
            return
        }
        val capturedAt = SystemClock.uptimeMillis()
        runCatching {
            // ArUco画像を鏡像にすると辞書のビット列が変わり認識できないため、
            // 検出は元画像で行い、検出後の座標だけをプレビュー座標へ反転する。
            val bitmap = image.toCorrectedBitmap()
            val rgba = Mat()
            val gray = Mat()
            val ids = Mat()
            val corners = mutableListOf<Mat>()
            try {
                Utils.bitmapToMat(bitmap, rgba)
                Imgproc.cvtColor(rgba, gray, Imgproc.COLOR_RGBA2GRAY)
                activeDetector.detectMarkers(gray, corners, ids)
                val rawMarkers = corners.mapIndexedNotNull { index, cornerMat ->
                    val id = ids.get(index, 0)?.firstOrNull()?.toInt() ?: return@mapIndexedNotNull null
                    if (id !in MarkerStabilityTracker.EXPECTED_IDS) return@mapIndexedNotNull null
                    val normalizedCorners = (0 until 4).mapNotNull { cornerIndex ->
                        cornerMat.get(0, cornerIndex)?.let { point ->
                            NormalizedPoint(
                                x = (point[0] / bitmap.width).toFloat(),
                                y = (point[1] / bitmap.height).toFloat(),
                            )
                        }
                    }
                    if (normalizedCorners.size != 4) return@mapIndexedNotNull null
                    DetectedMarker(
                        id = id,
                        center = NormalizedPoint(
                            normalizedCorners.map { it.x }.average().toFloat(),
                            normalizedCorners.map { it.y }.average().toFloat(),
                        ),
                        corners = normalizedCorners,
                    )
                }.sortedBy { it.id }
                // ID 10=左上、11=右上というレイアウト検証は、鏡像化前のカメラ
                // 座標で行う。検証後に表示・送信用座標だけを水平反転する。
                val isStable = stabilityTracker.update(rawMarkers)
                val markers = if (mirror) {
                    rawMarkers.map(DetectedMarker::mirrorHorizontally)
                } else {
                    rawMarkers
                }
                AppDiagnostics.increment("aruco.frames")
                if (isStable) AppDiagnostics.increment("aruco.stable_frames")
                AppDiagnostics.gauge("aruco.marker_count", markers.size)
                AppDiagnostics.gauge("aruco.stable", isStable)
                AppDiagnostics.gauge(
                    "aruco.stability_progress",
                    "${stabilityTracker.stableFrameCount}/${MarkerStabilityTracker.DEFAULT_REQUIRED_STABLE_FRAMES}",
                )
                AppDiagnostics.sampled(
                    "aruco_result",
                    "vision",
                    "aruco_result",
                    mapOf(
                        "ids" to markers.joinToString { it.id.toString() },
                        "stable" to isStable,
                        "stableFrames" to stabilityTracker.stableFrameCount,
                        "mirrored" to mirror,
                        "centers" to markers.joinToString(";") { "${it.id}:${it.center.x},${it.center.y}" },
                    ),
                )
                onResult(
                    MarkerDetectionResult(
                        capturedAtMonotonicMs = capturedAt,
                        sourceWidth = bitmap.width,
                        sourceHeight = bitmap.height,
                        markers = markers,
                        stable = isStable,
                        stableFrameCount = stabilityTracker.stableFrameCount,
                        requiredStableFrames = MarkerStabilityTracker.DEFAULT_REQUIRED_STABLE_FRAMES,
                        cameraFacing = if (mirror) "front" else "back",
                    ),
                )
            } finally {
                corners.forEach(Mat::release)
                ids.release()
                gray.release()
                rgba.release()
            }
        }.onFailure {
            stabilityTracker.reset()
            AppDiagnostics.event("vision", "aruco_error", mapOf("message" to it.message))
            onError(it)
        }
    }

    fun reset() {
        stabilityTracker.reset()
        AppDiagnostics.event("vision", "aruco_reset")
    }
}
