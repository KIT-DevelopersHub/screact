package com.nxtend.team35.yubiboard.vision

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import kotlin.math.min

class ProductionOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    private val pointerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        strokeWidth = 5f
        style = Paint.Style.STROKE
    }
    private val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        strokeWidth = 5f
        style = Paint.Style.STROKE
    }
    private var hand: HandDetectionResult? = null
    private var markers: MarkerDetectionResult? = null

    fun setHandResult(result: HandDetectionResult) {
        hand = result
        markers = null
        invalidate()
    }

    fun setMarkerResult(result: MarkerDetectionResult) {
        markers = result
        hand = null
        invalidate()
    }

    fun clear() {
        hand = null
        markers = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        markers?.let { drawMarkers(canvas, it); return }
        val current = hand ?: return
        val point = current.landmarks.getOrNull(8) ?: return
        val mapped = map(point.x, point.y, current.sourceWidth, current.sourceHeight)
        canvas.drawCircle(mapped.first, mapped.second, 18f, pointerPaint)
        canvas.drawCircle(mapped.first, mapped.second, 7f, pointerPaint)
    }

    private fun drawMarkers(canvas: Canvas, result: MarkerDetectionResult) {
        result.markers.forEach { marker ->
            marker.corners.indices.forEach { index ->
                val start = marker.corners[index]
                val end = marker.corners[(index + 1) % marker.corners.size]
                val a = map(start.x, start.y, result.sourceWidth, result.sourceHeight)
                val b = map(end.x, end.y, result.sourceWidth, result.sourceHeight)
                canvas.drawLine(a.first, a.second, b.first, b.second, markerPaint)
            }
        }
    }

    private fun map(x: Float, y: Float, sourceWidth: Int, sourceHeight: Int): Pair<Float, Float> {
        if (sourceWidth <= 0 || sourceHeight <= 0) return 0f to 0f
        val scale = min(width / sourceWidth.toFloat(), height / sourceHeight.toFloat())
        val offsetX = (width - sourceWidth * scale) / 2f
        val offsetY = (height - sourceHeight * scale) / 2f
        return (offsetX + x * sourceWidth * scale) to (offsetY + y * sourceHeight * scale)
    }
}
