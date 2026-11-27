package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HandTrackAssignerTest {
    @Test
    fun `keeps ids when MediaPipe order changes`() {
        val assigner = HandTrackAssigner()
        val first = assigner.assign(listOf(handAt(0.2f), handAt(0.8f)), 1_000)
        val second = assigner.assign(listOf(handAt(0.78f), handAt(0.22f)), 1_050)

        assertEquals(first.map { it.trackId }, second.map { it.trackId })
        assertEquals(0.22f, second[0].landmarks[0].x)
        assertEquals(0.78f, second[1].landmarks[0].x)
    }

    @Test
    fun `restores a briefly missing hand but removes it from current frame`() {
        val assigner = HandTrackAssigner()
        val original = assigner.assign(listOf(handAt(0.3f), handAt(0.7f)), 1_000)
        val visible = assigner.assign(listOf(handAt(0.31f)), 1_100)
        val restored = assigner.assign(listOf(handAt(0.32f), handAt(0.69f)), 1_250)

        assertEquals(listOf(original[0].trackId), visible.map { it.trackId })
        assertEquals(original.map { it.trackId }, restored.map { it.trackId })
    }

    @Test
    fun `allocates a new id after retention expires`() {
        val assigner = HandTrackAssigner()
        val original = assigner.assign(listOf(handAt(0.4f)), 1_000).single().trackId
        assertTrue(assigner.assign(emptyList(), 1_301).isEmpty())
        val replacement = assigner.assign(listOf(handAt(0.4f)), 1_302).single().trackId

        assertNotEquals(original, replacement)
    }

    @Test
    fun `distance gate prevents an implausible id jump`() {
        val assigner = HandTrackAssigner()
        val original = assigner.assign(listOf(handAt(0.1f)), 1_000).single().trackId
        val far = assigner.assign(listOf(handAt(0.9f)), 1_010).single().trackId

        assertNotEquals(original, far)
    }

    @Test
    fun `drops malformed and non finite candidates`() {
        val assigner = HandTrackAssigner()
        val short = HandCandidate(List(20) { LandmarkPoint(0.5f, 0.5f, 0f) })
        val infinite = HandCandidate(List(21) { LandmarkPoint(Float.POSITIVE_INFINITY, 0.5f, 0f) })

        assertTrue(assigner.assign(listOf(short, infinite), 1_000).isEmpty())
    }

    // --- 交差・近接・遮蔽・画面外移動の再現（#19） ---
    // 手は 30fps 相当（33ms 間隔）の合成軌跡で動かす。どの候補がどの手かは z に入れたラベルで見分ける。

    @Test
    fun `crossing hands swap ids with distance-only matching`() {
        val scene = Scene()
        val handA = linearPath(startX = 0.36f, startY = 0.50f, stepX = 0.04f, frames = 8)
        val handB = linearPath(startX = 0.64f, startY = 0.51f, stepX = -0.04f, frames = 8)
        val frames = handA.indices.map { i -> scene.frame(hand(A, handA[i]), hand(B, handB[i])) }

        val initial = frames.first()
        assertNotEquals(initial[A], initial[B])
        // 現状の挙動: 2 手が最も近づいた直後（4 フレーム目）に ID が入れ替わり、そのまま戻らない。
        // #20 で速度予測を入れて改善予定。
        assertEquals(initial, frames[3])
        assertEquals(initial[B], frames[4][A])
        assertEquals(initial[A], frames[4][B])
        assertEquals(initial[B], frames.last()[A])
        assertEquals(initial[A], frames.last()[B])
    }

    @Test
    fun `hands moving side by side keep ids`() {
        val scene = Scene()
        val handA = linearPath(startX = 0.47f, startY = 0.30f, stepY = 0.02f, frames = 8)
        val handB = linearPath(startX = 0.53f, startY = 0.30f, stepY = 0.02f, frames = 8)
        val frames = handA.indices.map { i -> scene.frame(hand(A, handA[i]), hand(B, handB[i])) }

        assertNotEquals(frames.first()[A], frames.first()[B])
        frames.forEach { assertEquals(frames.first(), it) }
    }

    @Test
    fun `side by side hands swap ids for one frame when landmarks jitter`() {
        val scene = Scene()
        val handA = linearPath(startX = 0.47f, startY = 0.30f, stepY = 0.02f, frames = 6).toMutableList()
        val handB = linearPath(startX = 0.53f, startY = 0.30f, stepY = 0.02f, frames = 6).toMutableList()
        // 3 フレーム目だけ、推定のぶれで 2 手の中心が互いの側へ寄る。
        handA[3] = handA[3].copy(x = 0.505f)
        handB[3] = handB[3].copy(x = 0.495f)
        val frames = handA.indices.map { i ->
            scene.frame(
                hand(A, handA[i], handedness = "LEFT", handednessScore = 0.95f),
                hand(B, handB[i], handedness = "RIGHT", handednessScore = 0.95f),
            )
        }

        val initial = frames.first()
        assertEquals(initial, frames[2])
        // 現状の挙動: ぶれたフレームだけ ID が入れ替わる（handedness は使っていない）。
        // #20 で左右判定を入れて改善予定。
        assertEquals(initial[B], frames[3][A])
        assertEquals(initial[A], frames[3][B])
        assertEquals(initial, frames[4])
        assertEquals(initial, frames.last())
    }

    @Test
    fun `hand reappearing past the other hand takes its id with distance-only matching`() {
        val scene = Scene()
        val handA = linearPath(startX = 0.40f, startY = 0.50f, stepX = 0.04f, frames = 7)
        val before = (0..2).map { i -> scene.frame(hand(A, handA[i]), hand(B, Point(0.56f, 0.50f))) }
        // A が B の後ろに隠れている間は B だけが見える。
        val hidden = (3..5).map { scene.frame(hand(B, Point(0.56f, 0.50f))) }
        // A は B の反対側から現れ、B はわずかに左へ動く。
        val reappeared = scene.frame(hand(A, handA[6]), hand(B, Point(0.55f, 0.50f)))

        val initial = before.first()
        assertEquals(initial, before.last())
        hidden.forEach { assertEquals(mapOf(B to initial[B]), it) }
        // 現状の挙動: 再出現した A が B の ID を取り、B が A の ID を取る。
        // #20 で速度予測を入れて改善予定。
        assertEquals(initial[B], reappeared[A])
        assertEquals(initial[A], reappeared[B])
    }

    @Test
    fun `hand leaving one edge and entering from the opposite edge gets a new id`() {
        val scene = Scene()
        val handB = linearPath(startX = 0.70f, startY = 0.50f, stepX = 0.10f, frames = 3)
        val before = handB.map { scene.frame(hand(A, Point(0.15f, 0.50f)), hand(B, it)) }
        // B が右端から出て、2 フレーム後（保持時間内）に左端から入ってくる。
        val exited = (0..1).map { scene.frame(hand(A, Point(0.15f, 0.50f))) }
        val entered = scene.frame(hand(A, Point(0.15f, 0.50f)), hand(B, Point(0.05f, 0.50f)))

        val initial = before.first()
        assertEquals(initial, before.last())
        exited.forEach { assertEquals(mapOf(A to initial[A]), it) }
        assertEquals(initial[A], entered[A])
        assertNotEquals(initial[A], entered[B])
        assertNotEquals(initial[B], entered[B])
    }

    @Test
    fun `hand leaving the frame and coming back on the same edge keeps its id`() {
        val scene = Scene()
        val handB = linearPath(startX = 0.70f, startY = 0.50f, stepX = 0.10f, frames = 3)
        val before = handB.map { scene.frame(hand(A, Point(0.15f, 0.50f)), hand(B, it)) }
        repeat(3) { scene.frame(hand(A, Point(0.15f, 0.50f))) }
        val returned = scene.frame(hand(A, Point(0.15f, 0.50f)), hand(B, Point(0.92f, 0.50f)))

        assertEquals(before.first(), returned)
    }

    private data class Point(val x: Float, val y: Float)

    /** 等速で動く手のひら中心の軌跡を、フレームごとの点の列として作る。 */
    private fun linearPath(
        startX: Float,
        startY: Float,
        stepX: Float = 0f,
        stepY: Float = 0f,
        frames: Int,
    ): List<Point> = List(frames) { i -> Point(startX + stepX * i, startY + stepY * i) }

    /** ラベルを z に入れた手の候補。ランドマークはすべて同じ点に置く。 */
    private fun hand(
        label: Int,
        at: Point,
        handedness: String? = null,
        handednessScore: Float? = null,
    ) = HandCandidate(
        landmarks = List(21) { LandmarkPoint(at.x, at.y, label.toFloat()) },
        handedness = handedness,
        handednessScore = handednessScore,
    )

    /** 33ms 間隔でフレームを流し、ラベルごとの trackId を返す。 */
    private class Scene(private val assigner: HandTrackAssigner = HandTrackAssigner()) {
        private var timestampMs = 1_000L

        fun frame(vararg hands: HandCandidate): Map<Int, Int> {
            val tracked = assigner.assign(hands.toList(), timestampMs)
            timestampMs += FRAME_MS
            return tracked.associate { it.landmarks[0].z.toInt() to it.trackId }
        }
    }

    private fun handAt(x: Float) = HandCandidate(
        landmarks = List(21) { LandmarkPoint(x, 0.5f, -0.01f) },
    )

    private companion object {
        const val A = 1
        const val B = 2
        const val FRAME_MS = 33L
    }
}
