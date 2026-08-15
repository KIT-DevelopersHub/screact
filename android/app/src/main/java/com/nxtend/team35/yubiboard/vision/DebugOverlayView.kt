package com.nxtend.team35.yubiboard.vision

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import kotlin.math.min

class DebugOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeWidth = 5f
        style = Paint.Style.STROKE
    }
    private val pointPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val trackTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 30f
        style = Paint.Style.FILL
    }
    private var result: HandDetectionResult? = null
    private var markerResult: MarkerDetectionResult? = null
    private val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(255, 190, 46)
        strokeWidth = 6f
        style = Paint.Style.STROKE
    }
    private val markerTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 34f
        style = Paint.Style.FILL
    }

    fun setHandResult(result: HandDetectionResult) {
        this.result = result
        markerResult = null
        invalidate()
    }

    fun setMarkerResult(result: MarkerDetectionResult) {
        markerResult = result
        this.result = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        markerResult?.let {
            drawMarkers(canvas, it)
            return
        }
        val current = result ?: return
        if (!current.detected) return

        val sourceWidth = current.sourceWidth.toFloat()
        val sourceHeight = current.sourceHeight.toFloat()
        val scale = min(width / sourceWidth, height / sourceHeight)
        val offsetX = (width - sourceWidth * scale) / 2f
        val offsetY = (height - sourceHeight * scale) / 2f

        fun screenPoint(hand: TrackedHand, index: Int): Pair<Float, Float> {
            val landmark = hand.landmarks[index]
            return Pair(
                offsetX + landmark.x * sourceWidth * scale,
                offsetY + landmark.y * sourceHeight * scale,
            )
        }

        current.hands.forEach { hand ->
            if (hand.landmarks.size != 21) return@forEach
            val color = TRACK_COLORS[(hand.trackId - 1).mod(TRACK_COLORS.size)]
            linePaint.color = color
            pointPaint.color = color
            CONNECTIONS.forEach { (from, to) ->
                val start = screenPoint(hand, from)
                val end = screenPoint(hand, to)
                canvas.drawLine(start.first, start.second, end.first, end.second, linePaint)
            }
            hand.landmarks.indices.forEach { index ->
                val point = screenPoint(hand, index)
                canvas.drawCircle(point.first, point.second, 7f, pointPaint)
            }
            val wrist = screenPoint(hand, 0)
            canvas.drawText("ID ${hand.trackId}", wrist.first + 12f, wrist.second - 12f, trackTextPaint)
        }
    }

    private fun drawMarkers(canvas: Canvas, current: MarkerDetectionResult) {
        val sourceWidth = current.sourceWidth.toFloat()
        val sourceHeight = current.sourceHeight.toFloat()
        val scale = min(width / sourceWidth, height / sourceHeight)
        val offsetX = (width - sourceWidth * scale) / 2f
        val offsetY = (height - sourceHeight * scale) / 2f
        fun map(point: NormalizedPoint) = Pair(
            offsetX + point.x * sourceWidth * scale,
            offsetY + point.y * sourceHeight * scale,
        )

        current.markers.forEach { marker ->
            marker.corners.indices.forEach { index ->
                val start = map(marker.corners[index])
                val end = map(marker.corners[(index + 1) % marker.corners.size])
                canvas.drawLine(start.first, start.second, end.first, end.second, markerPaint)
            }
            val center = map(marker.center)
            canvas.drawText("ID ${marker.id}", center.first + 10f, center.second - 10f, markerTextPaint)
        }
    }

    companion object {
        private val TRACK_COLORS = intArrayOf(
            Color.rgb(59, 220, 182),
            Color.rgb(255, 145, 82),
        )
        private val CONNECTIONS = listOf(
            0 to 1, 1 to 2, 2 to 3, 3 to 4,
            0 to 5, 5 to 6, 6 to 7, 7 to 8,
            5 to 9, 9 to 10, 10 to 11, 11 to 12,
            9 to 13, 13 to 14, 14 to 15, 15 to 16,
            13 to 17, 17 to 18, 18 to 19, 19 to 20,
            0 to 17,
        )
    }
}
