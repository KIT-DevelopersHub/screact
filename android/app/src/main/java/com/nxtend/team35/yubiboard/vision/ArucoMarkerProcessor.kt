package com.nxtend.team35.yubiboard.vision

import android.os.SystemClock
import androidx.camera.core.ImageProxy
import com.nxtend.team35.yubiboard.camera.toCorrectedBitmap
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

    fun process(image: ImageProxy) {
        val activeDetector = detector
        if (activeDetector == null) {
            image.close()
            return
        }
        val capturedAt = SystemClock.uptimeMillis()
        runCatching {
            val bitmap = image.toCorrectedBitmap()
            val rgba = Mat()
            val gray = Mat()
            val ids = Mat()
            val corners = mutableListOf<Mat>()
            try {
                Utils.bitmapToMat(bitmap, rgba)
                Imgproc.cvtColor(rgba, gray, Imgproc.COLOR_RGBA2GRAY)
                activeDetector.detectMarkers(gray, corners, ids)
                val markers = corners.mapIndexedNotNull { index, cornerMat ->
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
                onResult(
                    MarkerDetectionResult(
                        capturedAtMonotonicMs = capturedAt,
                        sourceWidth = bitmap.width,
                        sourceHeight = bitmap.height,
                        markers = markers,
                        stable = stabilityTracker.update(markers),
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
            onError(it)
        }
    }
}
