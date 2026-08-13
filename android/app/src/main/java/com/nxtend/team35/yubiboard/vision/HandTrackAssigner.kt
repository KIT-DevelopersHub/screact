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
    )

    private val tracks = mutableListOf<Track>()
    private var nextTrackId = 1

    @Synchronized
    fun assign(candidates: List<HandCandidate>, timestampMs: Long): List<TrackedHand> {
        require(candidates.size <= MAX_HANDS) { "At most $MAX_HANDS hands are supported" }
        val validCandidates = candidates.filter(::isValidCandidate)
        tracks.removeAll { timestampMs - it.lastSeenAtMs > retentionMs }

        val centers = validCandidates.map(::palmCenter)
        val assignments = bestAssignments(centers)
        val result = validCandidates.mapIndexed { index, candidate ->
            val track = assignments[index]?.also {
                it.center = centers[index]
                it.lastSeenAtMs = timestampMs
            } ?: Track(
                id = nextTrackId++,
                center = centers[index],
                lastSeenAtMs = timestampMs,
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

    private fun bestAssignments(centers: List<Center>): List<Track?> {
        if (centers.isEmpty()) return emptyList()
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
                val candidateDistance = distance(centers[index], track.center)
                if (candidateDistance > matchDistance) return@forEach
                selected += track
                visit(index + 1, selected, used + track.id, distance + candidateDistance)
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
        private val PALM_LANDMARKS = listOf(0, 5, 9, 13, 17)
    }
}
