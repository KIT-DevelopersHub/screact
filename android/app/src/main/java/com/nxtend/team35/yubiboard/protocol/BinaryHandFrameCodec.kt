package com.nxtend.team35.yubiboard.protocol

import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.sign
import kotlin.math.truncate

/**
 * 手指フレームのバイナリ形式（仕様案、formatVersion 1）のエンコーダ。
 *
 * 仕様は Desktop 側の docs/system/binary-hand-frame-draft.md、対になるデコーダは
 * desktop/lib/protocol/binary_hand_frame.dart（`BinaryHandFrameCodec`）。両者の互換は
 * docs/system/binary-hand-frame-test-vectors.json の固定値で確かめる。
 * 本番の WebSocket 送信（JSON `hand_frame`）にはまだ使わない。
 *
 * すべてリトルエンディアン。
 *
 * ```text
 * ヘッダ 12 B : magic u8 | formatVersion u8 | flags u8 | handCount u8
 *               | frameId u32 | capturedAtMonotonicMs u32
 * ソース 6 B  : width u16 | height u16 | rotationQuarter u8 | sourceFlags u8
 *               （flags.hasSource のときだけ）
 * 手 × handCount :
 *   trackId u16 | handedness u8 | handednessScore u8
 *   | 21 × (x u16, y u16) | 21 × z i16（flags.hasZ のときだけ）
 * ```
 */
object BinaryHandFrameCodec {
    /** 先頭バイト（'S'）。JSON（'{'）と取り違えないための目印。 */
    const val MAGIC = 0x53

    /** 1 は protocol schemaVersion 1 の `hand_frame` に対応する。 */
    const val FORMAT_VERSION = 1

    const val FLAG_HAS_Z = 0x01
    const val FLAG_HAS_SOURCE = 0x02

    const val HEADER_SIZE = 12
    const val SOURCE_SIZE = 6
    const val LANDMARK_COUNT = 21
    const val HAND_FIXED_SIZE = 4
    const val HAND_XY_SIZE = LANDMARK_COUNT * 4
    const val HAND_Z_SIZE = LANDMARK_COUNT * 2
    const val MAX_HANDS = 2
    const val MAX_TRACK_ID = 0xFFFF
    const val MAX_UINT32 = 0xFFFFFFFFL

    /** x/y の量子化: q = round(v × 65535)。 */
    const val XY_SCALE = 0xFFFF

    /** z の量子化: q = round(clamp(z, -1, 1) × 32767)。範囲外は ±1 に飽和する。 */
    const val Z_SCALE = 0x7FFF
    const val Z_RANGE = 1.0

    /** handednessScore の量子化: q = round(s × 254)。255 は「省略」。 */
    const val SCORE_SCALE = 254
    const val SCORE_ABSENT = 0xFF

    fun handSize(includeZ: Boolean): Int =
        HAND_FIXED_SIZE + HAND_XY_SIZE + if (includeZ) HAND_Z_SIZE else 0

    fun frameSize(handCount: Int, includeZ: Boolean, includeSource: Boolean): Int =
        HEADER_SIZE + (if (includeSource) SOURCE_SIZE else 0) + handCount * handSize(includeZ)

    /**
     * [frame] をバイト列にする。仕様で表せない値は [IllegalArgumentException]。
     * z だけは範囲外を ±1 に飽和させる。手は trackId の昇順・重複なしで渡す。
     */
    fun encode(frame: BinaryHandFrame): ByteArray {
        val hands = frame.hands
        require(hands.size <= MAX_HANDS) { "hands.size must be 0..$MAX_HANDS: ${hands.size}" }
        requireUint32(frame.frameId, "frameId")
        requireUint32(frame.capturedAtMonotonicMs, "capturedAtMonotonicMs")
        val source = frame.source
        val size = frameSize(hands.size, frame.includeZ, source != null)
        val buffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(MAGIC.toByte())
        buffer.put(FORMAT_VERSION.toByte())
        var flags = 0
        if (frame.includeZ) flags = flags or FLAG_HAS_Z
        if (source != null) flags = flags or FLAG_HAS_SOURCE
        buffer.put(flags.toByte())
        buffer.put(hands.size.toByte())
        buffer.putInt(frame.frameId.toInt())
        buffer.putInt(frame.capturedAtMonotonicMs.toInt())

        if (source != null) {
            require(source.width in 0..0xFFFF) { "source.width must be u16: ${source.width}" }
            require(source.height in 0..0xFFFF) { "source.height must be u16: ${source.height}" }
            val rotation = source.rotationDegrees
            require(rotation in 0 until 360 && rotation % 90 == 0) {
                "source.rotationDegrees must be 0/90/180/270: $rotation"
            }
            buffer.putShort(source.width.toShort())
            buffer.putShort(source.height.toShort())
            buffer.put((rotation / 90).toByte())
            var sourceFlags = encodeFacing(source.cameraFacing) shl 2
            if (source.rotationCorrected) sourceFlags = sourceFlags or 0x01
            if (source.mirrorCorrected) sourceFlags = sourceFlags or 0x02
            buffer.put(sourceFlags.toByte())
        }

        var previousId = 0
        for (hand in hands) {
            require(hand.trackId in 1..MAX_TRACK_ID) { "trackId must be 1..$MAX_TRACK_ID: ${hand.trackId}" }
            require(hand.trackId > previousId) { "trackId must be ascending without duplicates: ${hand.trackId}" }
            previousId = hand.trackId
            require(hand.landmarks.size == LANDMARK_COUNT) {
                "landmarks must have $LANDMARK_COUNT points: ${hand.landmarks.size}"
            }
            buffer.putShort(hand.trackId.toShort())
            buffer.put(encodeHandedness(hand.handedness).toByte())
            buffer.put(quantizeScore(hand.handednessScore).toByte())
            for (point in hand.landmarks) {
                buffer.putShort(quantizeXy(point.x, "x").toShort())
                buffer.putShort(quantizeXy(point.y, "y").toShort())
            }
            if (frame.includeZ) {
                for (point in hand.landmarks) {
                    buffer.putShort(quantizeZ(point.z).toShort())
                }
            }
        }
        check(buffer.position() == size)
        return buffer.array()
    }

    /** x/y（0〜1）を u16 に量子化する。範囲外・非有限はエラー。 */
    fun quantizeXy(value: Double, name: String = "x/y"): Int {
        require(value.isFinite() && value in 0.0..1.0) { "$name must be finite and in 0..1: $value" }
        return roundHalfAwayFromZero(value * XY_SCALE).toInt()
    }

    /** z を i16 に量子化する。範囲外は ±1 に飽和、非有限はエラー。 */
    fun quantizeZ(value: Double): Int {
        require(value.isFinite()) { "z must be finite: $value" }
        return roundHalfAwayFromZero(value.coerceIn(-Z_RANGE, Z_RANGE) / Z_RANGE * Z_SCALE).toInt()
    }

    /** handednessScore（0〜1、null は省略）を u8 に量子化する。 */
    fun quantizeScore(value: Double?): Int {
        if (value == null) return SCORE_ABSENT
        require(value.isFinite() && value in 0.0..1.0) { "handednessScore must be finite and in 0..1: $value" }
        return roundHalfAwayFromZero(value * SCORE_SCALE).toInt()
    }

    /**
     * Desktop（Dart の `double.round()`）と同じく、0.5 ちょうどは 0 から遠い側へ丸める。
     * Kotlin の roundToInt（Math.round）は負の 0.5 を 0 側へ丸めるため使わない。
     */
    internal fun roundHalfAwayFromZero(value: Double): Double {
        val whole = truncate(value)
        return if (abs(value - whole) >= 0.5) whole + sign(value) else whole
    }

    private fun encodeHandedness(value: String?): Int = when (value) {
        null -> 0
        "LEFT" -> 1
        "RIGHT" -> 2
        else -> throw IllegalArgumentException("handedness must be null / LEFT / RIGHT: $value")
    }

    private fun encodeFacing(value: String?): Int = when (value) {
        null -> 0
        "front" -> 1
        "back" -> 2
        else -> throw IllegalArgumentException("source.cameraFacing must be null / front / back: $value")
    }

    private fun requireUint32(value: Long, name: String) {
        require(value in 0..MAX_UINT32) { "$name must be u32: $value" }
    }
}

/** JSON の `source` に当たる撮影情報。 */
data class BinaryHandFrameSource(
    val width: Int,
    val height: Int,
    /** 0 / 90 / 180 / 270。 */
    val rotationDegrees: Int = 0,
    val rotationCorrected: Boolean = false,
    val mirrorCorrected: Boolean = false,
    /** `front` / `back` / null（省略）。 */
    val cameraFacing: String? = null,
)

/** 点 1 つ。x / y は 0〜1、z は MediaPipe の相対深度。 */
data class BinaryLandmark(val x: Double, val y: Double, val z: Double = 0.0)

/** 手 1 件（JSON の `hands[]` の要素に当たる）。 */
data class BinaryHand(
    /** 1〜65535。 */
    val trackId: Int,
    /** 21 点。 */
    val landmarks: List<BinaryLandmark>,
    /** `LEFT` / `RIGHT` / null。 */
    val handedness: String? = null,
    /** 0〜1 / null。 */
    val handednessScore: Double? = null,
)

/** 手指フレーム。手が 0 件なら「未検出」の通知になる。 */
data class BinaryHandFrame(
    /** u32。 */
    val frameId: Long,
    /** u32。 */
    val capturedAtMonotonicMs: Long,
    /** trackId 昇順・重複なしの 0〜2 件。 */
    val hands: List<BinaryHand>,
    /** z を送るか。false なら受信側の z は 0。 */
    val includeZ: Boolean = true,
    val source: BinaryHandFrameSource? = null,
) {
    companion object {
        /**
         * 検出結果から作る。JSON 経路（YubiBoardWebSocketClient）と同じく、手を trackId 昇順に並べ、
         * x / y を 0〜1 に収める。frameId と時刻は u32 に収まるよう下位 32 ビットを使う（一周する）。
         */
        fun fromDetection(
            result: HandDetectionResult,
            frameId: Long,
            includeZ: Boolean = true,
            includeSource: Boolean = true,
            rotationDegrees: Int = 0,
            rotationCorrected: Boolean = true,
        ): BinaryHandFrame = BinaryHandFrame(
            frameId = frameId and BinaryHandFrameCodec.MAX_UINT32,
            capturedAtMonotonicMs = result.capturedAtMonotonicMs and BinaryHandFrameCodec.MAX_UINT32,
            includeZ = includeZ,
            source = if (includeSource) {
                BinaryHandFrameSource(
                    width = result.sourceWidth,
                    height = result.sourceHeight,
                    rotationDegrees = rotationDegrees,
                    rotationCorrected = rotationCorrected,
                    mirrorCorrected = result.mirrorCorrected,
                    cameraFacing = result.cameraFacing,
                )
            } else {
                null
            },
            hands = result.hands.sortedBy { it.trackId }.map { tracked ->
                BinaryHand(
                    trackId = tracked.trackId,
                    handedness = tracked.handedness,
                    handednessScore = tracked.handednessScore?.toDouble(),
                    landmarks = tracked.landmarks.map {
                        BinaryLandmark(
                            x = it.x.coerceIn(0f, 1f).toDouble(),
                            y = it.y.coerceIn(0f, 1f).toDouble(),
                            z = it.z.toDouble(),
                        )
                    },
                )
            },
        )
    }
}
