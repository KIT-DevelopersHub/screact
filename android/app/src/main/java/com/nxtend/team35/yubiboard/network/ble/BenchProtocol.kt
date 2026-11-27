package com.nxtend.team35.yubiboard.network.ble

import com.nxtend.team35.yubiboard.protocol.BinaryHand
import com.nxtend.team35.yubiboard.protocol.BinaryHandFrame
import com.nxtend.team35.yubiboard.protocol.BinaryHandFrameCodec
import com.nxtend.team35.yubiboard.protocol.BinaryHandFrameSource
import com.nxtend.team35.yubiboard.protocol.BinaryLandmark
import com.nxtend.team35.yubiboard.protocol.HandFrameMessage
import com.nxtend.team35.yubiboard.protocol.HandPayload
import com.nxtend.team35.yubiboard.protocol.ProtocolCodec
import com.nxtend.team35.yubiboard.protocol.SourceInfo
import com.nxtend.team35.yubiboard.protocol.TrackedHandPayload
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.sin

/**
 * 経路比較（BLE / WebSocket）の計測用プロトコル。本番の接続フローでは使わない。
 * PC 側の対になる実装は android/tools/ble-bench/bench.py。すべてリトルエンディアン。
 *
 * 制御（PC → Android）:
 * - PING  `[0x01][u32 seq]` → PONG `[0x81][u32 seq]` をすぐ返す。
 * - START `[0x02][u8 hands][u8 fps][u8 payloadKind]` → ACK `[0x82]`。
 * - STOP  `[0x03]` → STATS `[0x83][u32 × 6][u16 mtu]`（[BenchStats] の順）。
 *
 * フレーム（Android → PC）: 1 単位に収まるならペイロードをそのまま送る。
 * 収まらなければ `[0x46][u32 frameId][u8 index][u8 count]` を前置きして分割する。
 */
object BenchProtocol {
    const val CMD_PING: Byte = 0x01
    const val CMD_START: Byte = 0x02
    const val CMD_STOP: Byte = 0x03
    const val RSP_PONG: Byte = 0x81.toByte()
    const val RSP_ACK: Byte = 0x82.toByte()
    const val RSP_STATS: Byte = 0x83.toByte()
    const val FRAGMENT_MAGIC: Byte = 0x46
    const val FRAGMENT_HEADER_BYTES = 7

    const val PAYLOAD_BINARY = 0
    const val PAYLOAD_JSON = 1

    sealed interface Command {
        data class Ping(val seq: Long) : Command
        data class Start(val hands: Int, val fps: Int, val payloadKind: Int) : Command
        data object Stop : Command
    }

    fun parseCommand(bytes: ByteArray): Command? {
        if (bytes.isEmpty()) return null
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return when (buffer.get()) {
            CMD_PING -> if (bytes.size == 5) Command.Ping(buffer.int.toLong() and 0xFFFFFFFFL) else null
            CMD_START -> {
                if (bytes.size != 4) return null
                val hands = buffer.get().toInt() and 0xFF
                val fps = buffer.get().toInt() and 0xFF
                val kind = buffer.get().toInt() and 0xFF
                if (hands !in 0..2 || fps !in 1..120 || kind !in PAYLOAD_BINARY..PAYLOAD_JSON) null
                else Command.Start(hands, fps, kind)
            }
            CMD_STOP -> if (bytes.size == 1) Command.Stop else null
            else -> null
        }
    }

    fun pong(seq: Long): ByteArray = ByteBuffer.allocate(5).order(ByteOrder.LITTLE_ENDIAN)
        .put(RSP_PONG).putInt((seq and 0xFFFFFFFFL).toInt()).array()

    fun ack(): ByteArray = byteArrayOf(RSP_ACK)

    fun stats(stats: BenchStats, mtu: Int): ByteArray {
        val buffer = ByteBuffer.allocate(1 + 6 * 4 + 2).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put(RSP_STATS)
        listOf(
            stats.generated, stats.framesSent, stats.replacedUnsent,
            stats.unitsSent, stats.unitFailures, stats.payloadBytesSent,
        ).forEach { buffer.putInt((it and 0xFFFFFFFFL).toInt()) }
        buffer.putShort(mtu.coerceIn(0, 0xFFFF).toShort())
        return buffer.array()
    }

    /**
     * [payload] を 1 単位あたり [maxUnitBytes] 以内に分ける。収まるなら分割しない。
     */
    fun split(frameId: Long, payload: ByteArray, maxUnitBytes: Int): List<ByteArray> {
        if (payload.size <= maxUnitBytes) return listOf(payload)
        val chunk = maxUnitBytes - FRAGMENT_HEADER_BYTES
        require(chunk > 0) { "unit too small for fragmentation" }
        val count = (payload.size + chunk - 1) / chunk
        require(count <= 255) { "too many fragments" }
        return (0 until count).map { index ->
            val start = index * chunk
            val end = minOf(payload.size, start + chunk)
            ByteBuffer.allocate(FRAGMENT_HEADER_BYTES + (end - start)).order(ByteOrder.LITTLE_ENDIAN)
                .put(FRAGMENT_MAGIC)
                .putInt((frameId and 0xFFFFFFFFL).toInt())
                .put(index.toByte())
                .put(count.toByte())
                .put(payload, start, end - start)
                .array()
        }
    }
}

/** 送信側のカウンタ。STOP で PC に返す。 */
data class BenchStats(
    val generated: Long = 0,
    val framesSent: Long = 0,
    /** 送信待ちのフレームが新しいフレームで置き換えられた数（最新優先）。 */
    val replacedUnsent: Long = 0,
    val unitsSent: Long = 0,
    val unitFailures: Long = 0,
    val payloadBytesSent: Long = 0,
)

/**
 * 計測用の合成手指フレーム。点は frameId で滑らかに動く。
 */
object SyntheticHandFrames {
    private const val SOURCE_WIDTH = 1280
    private const val SOURCE_HEIGHT = 720

    fun landmarks(frameId: Long, trackId: Int): List<FloatArray> {
        val t = frameId / 30.0
        val baseX = if (trackId == 1) 0.35 else 0.65
        return (0 until BinaryHandFrameCodec.LANDMARK_COUNT).map { i ->
            val angle = t + i * 0.3
            floatArrayOf(
                (baseX + 0.1 * sin(angle) + i * 0.003).toFloat().coerceIn(0f, 1f),
                (0.5 + 0.1 * cos(angle) - i * 0.004).toFloat().coerceIn(0f, 1f),
                (-0.05 * sin(angle * 0.5)).toFloat(),
            )
        }
    }

    fun binary(frameId: Long, capturedAtMs: Long, handCount: Int): ByteArray =
        BinaryHandFrameCodec.encode(
            BinaryHandFrame(
                // u32 で一周させる（受信側は差分で比べる）。
                frameId = frameId and BinaryHandFrameCodec.MAX_UINT32,
                capturedAtMonotonicMs = capturedAtMs and BinaryHandFrameCodec.MAX_UINT32,
                hands = (1..handCount).map { trackId ->
                    BinaryHand(
                        trackId = trackId,
                        handedness = if (trackId == 1) "LEFT" else "RIGHT",
                        handednessScore = 0.97,
                        landmarks = landmarks(frameId, trackId).map {
                            BinaryLandmark(it[0].toDouble(), it[1].toDouble(), it[2].toDouble())
                        },
                    )
                },
                source = BinaryHandFrameSource(
                    SOURCE_WIDTH,
                    SOURCE_HEIGHT,
                    rotationCorrected = true,
                    mirrorCorrected = true,
                    cameraFacing = "back",
                ),
                includeZ = true,
            ),
        )

    /** 本番と同じ JSON `hand_frame`（互換用 `hand` と `source` つき）を UTF-8 で返す。 */
    fun json(frameId: Long, capturedAtMs: Long, handCount: Int): ByteArray {
        val hands = (1..handCount).map { trackId ->
            TrackedHandPayload(
                trackId = trackId,
                handedness = if (trackId == 1) "LEFT" else "RIGHT",
                handednessScore = 0.97f,
                landmarks = landmarks(frameId, trackId).map { it.toList() },
            )
        }
        val primary = hands.firstOrNull()
        val message = HandFrameMessage(
            sessionId = "bench-session-0000",
            frameId = frameId,
            capturedAtMonotonicMs = capturedAtMs,
            source = SourceInfo(SOURCE_WIDTH, SOURCE_HEIGHT),
            hands = hands,
            hand = if (primary != null) {
                HandPayload(true, primary.handedness, primary.handednessScore, landmarks = primary.landmarks)
            } else {
                HandPayload(detected = false)
            },
        )
        return ProtocolCodec.encode(message).toByteArray(Charsets.UTF_8)
    }
}
