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
        color = Color.rgb(59, 220, 182)
        strokeWidth = 5f
        style = Paint.Style.STROKE
    }
    private val pointPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
    }
    private var result: HandDetectionResult? = null

    fun setHandResult(result: HandDetectionResult) {
        this.result = result
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val current = result ?: return
        if (!current.detected || current.landmarks.size != 21) return

        val sourceWidth = current.sourceWidth.toFloat()
        val sourceHeight = current.sourceHeight.toFloat()
        val scale = min(width / sourceWidth, height / sourceHeight)
        val offsetX = (width - sourceWidth * scale) / 2f
        val offsetY = (height - sourceHeight * scale) / 2f

        fun screenPoint(index: Int): Pair<Float, Float> {
            val landmark = current.landmarks[index]
            return Pair(
                offsetX + landmark.x * sourceWidth * scale,
                offsetY + landmark.y * sourceHeight * scale,
            )
        }

        CONNECTIONS.forEach { (from, to) ->
            val start = screenPoint(from)
            val end = screenPoint(to)
            canvas.drawLine(start.first, start.second, end.first, end.second, linePaint)
        }
        current.landmarks.indices.forEach { index ->
            val point = screenPoint(index)
            canvas.drawCircle(point.first, point.second, 7f, pointPaint)
        }
    }

    companion object {
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
