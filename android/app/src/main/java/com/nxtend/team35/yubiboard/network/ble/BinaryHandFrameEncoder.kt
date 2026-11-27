package com.nxtend.team35.yubiboard.network.ble

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * 手指フレームのバイナリ形式（docs/system/binary-hand-frame-draft.md の仕様案、formatVersion 1）の
 * 計測用エンコーダ。BLE PoC の帯域計測に必要な範囲だけを実装する（デコーダは持たない）。
 */
object BinaryHandFrameEncoder {
    const val MAGIC: Byte = 0x53
    const val FORMAT_VERSION: Byte = 1
    const val HEADER_BYTES = 12
    const val SOURCE_BYTES = 6
    const val LANDMARKS = 21
    const val HAND_BYTES_NO_Z = 4 + LANDMARKS * 4
    const val HAND_BYTES_WITH_Z = HAND_BYTES_NO_Z + LANDMARKS * 2

    private const val FLAG_HAS_Z = 0x01
    private const val FLAG_HAS_SOURCE = 0x02

    data class Source(
        val width: Int,
        val height: Int,
        val rotationQuarter: Int = 0,
        val rotationCorrected: Boolean = true,
        val mirrorCorrected: Boolean = true,
        /** 0 = 省略、1 = front、2 = back。 */
        val cameraFacing: Int = 2,
    )

    data class Hand(
        val trackId: Int,
        /** 0 = 省略、1 = LEFT、2 = RIGHT。 */
        val handedness: Int,
        /** 0〜1。null は省略。 */
        val handednessScore: Float?,
        /** 21 点の [x, y, z]。 */
        val landmarks: List<FloatArray>,
    )

    fun encodedSize(handCount: Int, hasZ: Boolean, hasSource: Boolean): Int =
        HEADER_BYTES + (if (hasSource) SOURCE_BYTES else 0) +
            handCount * (if (hasZ) HAND_BYTES_WITH_Z else HAND_BYTES_NO_Z)

    fun encode(
        frameId: Long,
        capturedAtMonotonicMs: Long,
        hands: List<Hand>,
        source: Source? = null,
        hasZ: Boolean = true,
    ): ByteArray {
        require(hands.size <= 2) { "handCount must be 0..2" }
        val sorted = hands.sortedBy { it.trackId }
        sorted.zipWithNext().forEach { (a, b) -> require(a.trackId != b.trackId) { "duplicate trackId" } }
        val buffer = ByteBuffer.allocate(encodedSize(hands.size, hasZ, source != null))
            .order(ByteOrder.LITTLE_ENDIAN)
        var flags = 0
        if (hasZ) flags = flags or FLAG_HAS_Z
        if (source != null) flags = flags or FLAG_HAS_SOURCE
        buffer.put(MAGIC)
        buffer.put(FORMAT_VERSION)
        buffer.put(flags.toByte())
        buffer.put(hands.size.toByte())
        buffer.putInt((frameId and 0xFFFFFFFFL).toInt())
        buffer.putInt((capturedAtMonotonicMs and 0xFFFFFFFFL).toInt())
        if (source != null) {
            require(source.rotationQuarter in 0..3)
            require(source.cameraFacing in 0..2)
            buffer.putShort(u16(source.width))
            buffer.putShort(u16(source.height))
            buffer.put(source.rotationQuarter.toByte())
            var sourceFlags = 0
            if (source.rotationCorrected) sourceFlags = sourceFlags or 0x01
            if (source.mirrorCorrected) sourceFlags = sourceFlags or 0x02
            sourceFlags = sourceFlags or (source.cameraFacing shl 2)
            buffer.put(sourceFlags.toByte())
        }
        for (hand in sorted) {
            require(hand.trackId in 1..0xFFFF) { "trackId out of range" }
            require(hand.handedness in 0..2)
            require(hand.landmarks.size == LANDMARKS) { "landmarks must have 21 points" }
            buffer.putShort(u16(hand.trackId))
            buffer.put(hand.handedness.toByte())
            val score = hand.handednessScore
            if (score == null) {
                buffer.put(0xFF.toByte())
            } else {
                require(score.isFinite() && score in 0f..1f) { "handednessScore out of range" }
                buffer.put((score * 254f).roundToInt().toByte())
            }
            for (point in hand.landmarks) {
                buffer.putShort(quantizeUnit(point[0]))
                buffer.putShort(quantizeUnit(point[1]))
            }
            if (hasZ) {
                for (point in hand.landmarks) {
                    val z = if (point.size > 2) point[2] else 0f
                    require(z.isFinite()) { "z must be finite" }
                    buffer.putShort((z.coerceIn(-1f, 1f) * 32767f).roundToInt().toShort())
                }
            }
        }
        return buffer.array()
    }

    private fun u16(value: Int): Short {
        require(value in 0..0xFFFF)
        return value.toShort()
    }

    private fun quantizeUnit(value: Float): Short {
        require(value.isFinite() && value in 0f..1f) { "x/y must be in 0..1" }
        return (value.toDouble() * 65535.0).roundToInt().toShort()
    }
}
