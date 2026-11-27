package com.nxtend.team35.yubiboard.vision

import kotlin.math.hypot

class HandTrackAssigner(
    private val matchDistance: Float = DEFAULT_MATCH_DISTANCE,
    private val retentionMs: Long = DEFAULT_RETENTION_MS,
) {
    private data class Center(val x: Float, val y: Float)

    private data class Track(
        val id: Int,
        var center: Center,
        var lastSeenAtMs: Long,
        /** 手のひら中心の速度（正規化座標 / ms）。観測が 1 回だけのあいだは 0。 */
        var velocityX: Float = 0f,
        var velocityY: Float = 0f,
        var observations: Int = 1,
        /** 最後に確かだった左右の判定（大文字）。確かな判定がまだなければ null。 */
        var handedness: String? = null,
    ) {
        /** 等速を仮定した、timestampMs 時点の手のひら中心の予測。 */
        fun predictedCenter(timestampMs: Long): Center {
            val elapsedMs = (timestampMs - lastSeenAtMs).coerceIn(0L, MAX_PREDICTION_MS).toFloat()
            return Center(center.x + velocityX * elapsedMs, center.y + velocityY * elapsedMs)
        }

        fun update(newCenter: Center, timestampMs: Long, newHandedness: String?) {
            val elapsedMs = timestampMs - lastSeenAtMs
            if (elapsedMs > 0) {
                val measuredX = (newCenter.x - center.x) / elapsedMs
                val measuredY = (newCenter.y - center.y) / elapsedMs
                if (observations == 1) {
                    velocityX = measuredX
                    velocityY = measuredY
                } else {
                    velocityX += VELOCITY_SMOOTHING * (measuredX - velocityX)
                    velocityY += VELOCITY_SMOOTHING * (measuredY - velocityY)
                }
                observations++
            }
            center = newCenter
            lastSeenAtMs = timestampMs
            if (newHandedness != null) handedness = newHandedness
        }
    }

    private val tracks = mutableListOf<Track>()
    private var nextTrackId = 1

    @Synchronized
    fun assign(candidates: List<HandCandidate>, timestampMs: Long): List<TrackedHand> {
        require(candidates.size <= MAX_HANDS) { "At most $MAX_HANDS hands are supported" }
        val validCandidates = candidates.filter(::isValidCandidate)
        tracks.removeAll { timestampMs - it.lastSeenAtMs > retentionMs }

        val centers = validCandidates.map(::palmCenter)
        val handedness = validCandidates.map(::confidentHandedness)
        val assignments = bestAssignments(centers, handedness, timestampMs)
        val result = validCandidates.mapIndexed { index, candidate ->
            val track = assignments[index]?.also {
                it.update(centers[index], timestampMs, handedness[index])
            } ?: Track(
                id = nextTrackId++,
                center = centers[index],
                lastSeenAtMs = timestampMs,
                handedness = handedness[index],
            ).also(tracks::add)
            TrackedHand(
                trackId = track.id,
                landmarks = candidate.landmarks,
                handedness = candidate.handedness,
                handednessScore = candidate.handednessScore,
            )
        }
        return result.sortedBy(TrackedHand::trackId)
    }

    /**
     * 対応付けの数を最大にしたうえで、コストの合計が最小になる組み合わせを選ぶ。
     * 対応付けてよいかは、これまでどおり前回の手のひら中心からの距離（matchDistance）で決める。
     * コストは等速予測した位置からの距離で、確かな左右の判定が食い違う組み合わせには罰則を足す。
     */
    private fun bestAssignments(
        centers: List<Center>,
        handedness: List<String?>,
        timestampMs: Long,
    ): List<Track?> {
        if (centers.isEmpty()) return emptyList()
        val predicted = tracks.associate { it.id to it.predictedCenter(timestampMs) }
        var best: List<Track?> = List(centers.size) { null }
        var bestMatched = -1
        var bestDistance = Float.POSITIVE_INFINITY

        fun visit(index: Int, selected: MutableList<Track?>, used: Set<Int>, distance: Float) {
            if (index == centers.size) {
                val matched = selected.count { it != null }
                if (matched > bestMatched || matched == bestMatched && distance < bestDistance) {
                    best = selected.toList()
                    bestMatched = matched
                    bestDistance = distance
                }
                return
            }
            selected += null
            visit(index + 1, selected, used, distance)
            selected.removeAt(selected.lastIndex)
            tracks.forEach { track ->
                if (track.id in used) return@forEach
                if (distance(centers[index], track.center) > matchDistance) return@forEach
                val cost = distance(centers[index], predicted.getValue(track.id)) +
                    handednessPenalty(handedness[index], track.handedness)
                selected += track
                visit(index + 1, selected, used + track.id, distance + cost)
                selected.removeAt(selected.lastIndex)
            }
        }

        visit(0, mutableListOf(), emptySet(), 0f)
        return best
    }

    private fun isValidCandidate(candidate: HandCandidate): Boolean =
        candidate.landmarks.size == HAND_LANDMARK_COUNT &&
            candidate.landmarks.all { it.x.isFinite() && it.y.isFinite() && it.z.isFinite() } &&
            (candidate.handednessScore == null ||
                candidate.handednessScore.isFinite() && candidate.handednessScore in 0f..1f)

    private fun confidentHandedness(candidate: HandCandidate): String? {
        val label = candidate.handedness?.uppercase() ?: return null
        val score = candidate.handednessScore ?: return null
        return label.takeIf { score >= HANDEDNESS_MIN_SCORE }
    }

    private fun handednessPenalty(candidate: String?, track: String?): Float =
        if (candidate != null && track != null && candidate != track) HANDEDNESS_PENALTY else 0f

    private fun palmCenter(candidate: HandCandidate): Center {
        val points = PALM_LANDMARKS.map(candidate.landmarks::get)
        return Center(points.sumOf { it.x.toDouble() }.toFloat() / points.size,
            points.sumOf { it.y.toDouble() }.toFloat() / points.size)
    }

    private fun distance(left: Center, right: Center): Float =
        hypot(left.x - right.x, left.y - right.y)

    companion object {
        const val MAX_HANDS = 2
        const val DEFAULT_MATCH_DISTANCE = 0.25f
        const val DEFAULT_RETENTION_MS = 300L
        private const val HAND_LANDMARK_COUNT = 21

        /** 予測に使う経過時間の上限。長く見えていない手を遠くまで外挿しない。 */
        private const val MAX_PREDICTION_MS = 200L

        /** 速度の指数平滑の係数。1 に近いほど直近のフレームを重く見る。 */
        private const val VELOCITY_SMOOTHING = 0.5f

        /** この確からしさ以上の handedness だけを対応付けに使う。 */
        private const val HANDEDNESS_MIN_SCORE = 0.8f

        /** 確かな左右の判定が食い違う組み合わせに足すコスト（正規化座標の距離と同じ単位）。 */
        private const val HANDEDNESS_PENALTY = 0.1f
        private val PALM_LANDMARKS = listOf(0, 5, 9, 13, 17)
    }
}
