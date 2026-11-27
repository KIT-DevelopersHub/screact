package com.nxtend.team35.yubiboard.protocol

import com.nxtend.team35.yubiboard.vision.HandDetectionResult
import com.nxtend.team35.yubiboard.vision.LandmarkPoint
import com.nxtend.team35.yubiboard.vision.TrackedHand
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class BinaryHandFrameCodecTest {
    private fun hand(trackId: Int, x: Double = 0.5, z: Double = -2.0, handedness: String? = "RIGHT") = BinaryHand(
        trackId = trackId,
        handedness = handedness,
        handednessScore = 1.0,
        landmarks = List(BinaryHandFrameCodec.LANDMARK_COUNT) { BinaryLandmark(x, 0.0, z) },
    )

    private fun frame(
        vararg hands: BinaryHand,
        includeZ: Boolean = true,
        source: BinaryHandFrameSource? = null,
        frameId: Long = 1,
        capturedAt: Long = 0,
    ) = BinaryHandFrame(frameId, capturedAt, hands.toList(), includeZ, source)

    private fun encode(frame: BinaryHandFrame) = BinaryHandFrameCodec.encode(frame)

    // ---- 共通テストベクタ（Desktop のデコーダと同じ固定値） ----

    @Test
    fun matchesSharedTestVectors() {
        val vectors = loadVectors()
        assertTrue("ベクタが少なすぎる", vectors.size >= 5)
        for (vector in vectors) {
            val name = vector.getValue("name").jsonPrimitive.content
            val bytes = encode(parseFrame(vector.getValue("frame").jsonObject))
            assertEquals(name, vector.getValue("size").jsonPrimitive.int, bytes.size)
            assertEquals(name, vector.getValue("hex").jsonPrimitive.content, bytes.toHex())
        }
    }

    @Test
    fun detectionResultEncodesToSharedVector() {
        // one_hand_z_source と同じ入力を TrackedHand（Float）から作っても同じバイト列になる。
        val vector = loadVectors().single { it.getValue("name").jsonPrimitive.content == "one_hand_z_source" }
        val zCycle = floatArrayOf(-2f, -0.5f, 0f, 0.5f, 1.5f)
        val result = HandDetectionResult(
            capturedAtMonotonicMs = 19384521,
            sourceWidth = 960,
            sourceHeight = 540,
            hands = listOf(
                TrackedHand(
                    trackId = 7,
                    handedness = "LEFT",
                    handednessScore = 0.75f,
                    landmarks = List(21) { i ->
                        LandmarkPoint(if (i == 20) 1f else i / 32f, 1f - i / 64f, zCycle[i % 5])
                    },
                ),
            ),
            mirrorCorrected = true,
            cameraFacing = "front",
        )
        val frame = BinaryHandFrame.fromDetection(result, frameId = 0x01020304, rotationDegrees = 90)
        assertEquals(vector.getValue("hex").jsonPrimitive.content, encode(frame).toHex())
    }

    // ---- バイト配置・量子化 ----

    @Test
    fun sizesMatchDraftTable() {
        val source = BinaryHandFrameSource(1280, 720)
        assertEquals(12, encode(frame()).size)
        assertEquals(18, encode(frame(source = source)).size)
        assertEquals(100, encode(frame(hand(1), includeZ = false)).size)
        assertEquals(142, encode(frame(hand(1))).size)
        assertEquals(148, encode(frame(hand(1), source = source)).size)
        assertEquals(188, encode(frame(hand(1), hand(2), includeZ = false)).size)
        assertEquals(194, encode(frame(hand(1), hand(2), includeZ = false, source = source)).size)
        assertEquals(272, encode(frame(hand(1), hand(2))).size)
        assertEquals(278, encode(frame(hand(1), hand(2), source = source)).size)
    }

    @Test
    fun headerAndHandAreLittleEndian() {
        val bytes = encode(frame(hand(0x0107, x = 1.0), frameId = 0x01020304, capturedAt = 0xFFFFFFFFL))
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0x53, buffer.get().toInt())
        assertEquals(1, buffer.get().toInt())
        assertEquals(0x01, buffer.get().toInt()) // hasZ のみ
        assertEquals(1, buffer.get().toInt())
        assertEquals(0x01020304, buffer.int)
        assertEquals(-1, buffer.int) // u32 の最大値
        assertEquals(0x0107, buffer.short.toInt())
        assertEquals(2, buffer.get().toInt()) // RIGHT
        assertEquals(254, buffer.get().toInt() and 0xFF) // score 1.0
        assertEquals(0xFFFF, buffer.short.toInt() and 0xFFFF) // x = 1
        assertEquals(0, buffer.short.toInt()) // y = 0
        buffer.position(12 + 88)
        assertEquals(-32767, buffer.short.toInt()) // z = -2 は -1 に飽和
    }

    @Test
    fun quantizationRoundsHalfAwayFromZeroLikeDart() {
        assertEquals(32768, BinaryHandFrameCodec.quantizeXy(0.5))
        assertEquals(16384, BinaryHandFrameCodec.quantizeZ(0.5))
        // Math.round なら -16383 になる。Dart の round() と同じく -16384。
        assertEquals(-16384, BinaryHandFrameCodec.quantizeZ(-0.5))
        assertEquals(32767, BinaryHandFrameCodec.quantizeZ(5.0))
        assertEquals(-32767, BinaryHandFrameCodec.quantizeZ(-1e9))
        assertEquals(191, BinaryHandFrameCodec.quantizeScore(0.75))
        assertEquals(255, BinaryHandFrameCodec.quantizeScore(null))
        assertEquals(0.0, BinaryHandFrameCodec.roundHalfAwayFromZero(0.49999999999999994), 0.0)
        assertEquals(-3.0, BinaryHandFrameCodec.roundHalfAwayFromZero(-2.5), 0.0)
    }

    @Test
    fun sourceFlagsAreEncoded() {
        val bytes = encode(
            frame(
                source = BinaryHandFrameSource(
                    width = 960,
                    height = 540,
                    rotationDegrees = 270,
                    rotationCorrected = true,
                    mirrorCorrected = false,
                    cameraFacing = "back",
                ),
            ),
        )
        assertEquals(0x03, bytes[2].toInt()) // hasZ | hasSource
        assertEquals(3, bytes[16].toInt()) // 270 / 90
        assertEquals(0x01 or (2 shl 2), bytes[17].toInt())
    }

    // ---- 表せない値はエラー ----

    @Test
    fun rejectsUnrepresentableValues() {
        val cases: List<Pair<String, () -> BinaryHandFrame>> = listOf(
            "x > 1" to { frame(hand(1, x = 1.5)) },
            "x < 0" to { frame(hand(1, x = -0.1)) },
            "x NaN" to { frame(hand(1, x = Double.NaN)) },
            "z NaN" to { frame(hand(1, z = Double.NaN)) },
            "trackId 0" to { frame(hand(0)) },
            "trackId 65536" to { frame(hand(65536)) },
            "trackId 降順" to { frame(hand(5), hand(2)) },
            "trackId 重複" to { frame(hand(2), hand(2)) },
            "3 手" to { frame(hand(1), hand(2), hand(3)) },
            "handedness" to { frame(hand(1, handedness = "Left")) },
            "score > 1" to { frame(hand(1).copy(handednessScore = 1.5)) },
            "landmarks 20 点" to { frame(hand(1).copy(landmarks = hand(1).landmarks.drop(1))) },
            "frameId 負" to { frame(frameId = -1) },
            "frameId u32 超" to { frame(frameId = 0x1_0000_0000L) },
            "時刻 u32 超" to { frame(capturedAt = 0x1_0000_0000L) },
            "rotation 45" to { frame(source = BinaryHandFrameSource(1, 1, rotationDegrees = 45)) },
            "rotation 360" to { frame(source = BinaryHandFrameSource(1, 1, rotationDegrees = 360)) },
            "width u16 超" to { frame(source = BinaryHandFrameSource(65536, 1)) },
            "cameraFacing" to { frame(source = BinaryHandFrameSource(1, 1, cameraFacing = "side")) },
        )
        for ((name, build) in cases) {
            assertThrows(name, IllegalArgumentException::class.java) { encode(build()) }
        }
    }

    // ---- 検出結果からの変換 ----

    @Test
    fun fromDetectionSortsClampsAndWraps() {
        fun tracked(id: Int, x: Float) = TrackedHand(
            trackId = id,
            landmarks = List(21) { LandmarkPoint(x, -0.2f, 0f) },
            handedness = "LEFT",
        )
        val result = HandDetectionResult(
            capturedAtMonotonicMs = 0x1_0000_0010L,
            sourceWidth = 1280,
            sourceHeight = 720,
            hands = listOf(tracked(9, 1.2f), tracked(4, 0.25f)),
        )
        val frame = BinaryHandFrame.fromDetection(result, frameId = 0x1_0000_0002L, includeSource = false)
        assertEquals(2L, frame.frameId)
        assertEquals(0x10L, frame.capturedAtMonotonicMs)
        assertEquals(listOf(4, 9), frame.hands.map { it.trackId })
        assertEquals(1.0, frame.hands[1].landmarks[0].x, 0.0)
        assertEquals(0.0, frame.hands[0].landmarks[0].y, 0.0)
        assertEquals(null, frame.source)
        assertEquals(272, encode(frame).size)
    }

    @Test
    fun undetectedResultBecomesHeaderOnly() {
        val result = HandDetectionResult(capturedAtMonotonicMs = 100, sourceWidth = 640, sourceHeight = 480)
        val bytes = encode(BinaryHandFrame.fromDetection(result, frameId = 5, includeSource = false))
        assertEquals("53010100" + "05000000" + "64000000", bytes.toHex())
    }

    // ---- ベクタの読み込み ----

    private fun loadVectors(): List<JsonObject> {
        val text = vectorFile().readText(Charsets.UTF_8)
        return Json.parseToJsonElement(text).jsonObject.getValue("vectors").jsonArray.map { it.jsonObject }
    }

    /** ユニットテストの作業ディレクトリ（android/app）から上へたどって repo の docs を探す。 */
    private fun vectorFile(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, VECTOR_PATH)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        error("$VECTOR_PATH が見つからない")
    }

    private fun parseFrame(json: JsonObject): BinaryHandFrame {
        val source = json.getValue("source").takeUnless { it is JsonNull }?.jsonObject
        return BinaryHandFrame(
            frameId = json.getValue("frameId").jsonPrimitive.long,
            capturedAtMonotonicMs = json.getValue("capturedAtMonotonicMs").jsonPrimitive.long,
            includeZ = json.getValue("includeZ").jsonPrimitive.boolean,
            source = source?.let {
                BinaryHandFrameSource(
                    width = it.getValue("width").jsonPrimitive.int,
                    height = it.getValue("height").jsonPrimitive.int,
                    rotationDegrees = it.getValue("rotationDegrees").jsonPrimitive.int,
                    rotationCorrected = it.getValue("rotationCorrected").jsonPrimitive.boolean,
                    mirrorCorrected = it.getValue("mirrorCorrected").jsonPrimitive.boolean,
                    cameraFacing = it.getValue("cameraFacing").stringOrNull(),
                )
            },
            hands = json.getValue("hands").jsonArray.map { element ->
                val hand = element.jsonObject
                BinaryHand(
                    trackId = hand.getValue("trackId").jsonPrimitive.int,
                    handedness = hand.getValue("handedness").stringOrNull(),
                    handednessScore = hand.getValue("handednessScore").takeUnless { it is JsonNull }
                        ?.jsonPrimitive?.double,
                    landmarks = hand.getValue("landmarks").jsonArray.map { point ->
                        val p = point.jsonArray.map { it.jsonPrimitive.double }
                        BinaryLandmark(p[0], p[1], p[2])
                    },
                )
            },
        )
    }

    private fun JsonElement.stringOrNull(): String? = if (this is JsonNull) null else jsonPrimitive.content

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private companion object {
        const val VECTOR_PATH = "docs/system/binary-hand-frame-test-vectors.json"
    }
}
