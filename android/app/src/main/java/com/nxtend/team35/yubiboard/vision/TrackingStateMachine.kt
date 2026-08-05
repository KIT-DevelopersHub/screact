package com.nxtend.team35.yubiboard.vision

enum class TrackingState {
    UNDETECTED,
    CANDIDATE,
    TRACKING,
    TEMPORARILY_LOST,
}

class TrackingStateMachine(
    private val detectionsRequired: Int = 3,
    private val lossTimeoutMs: Long = 300,
) {
    var state: TrackingState = TrackingState.UNDETECTED
        private set
    private var consecutiveDetections = 0
    private var lostAtMs: Long? = null

    fun update(detected: Boolean, timestampMs: Long): TrackingState {
        if (detected) {
            lostAtMs = null
            consecutiveDetections++
            state = when (state) {
                TrackingState.TRACKING,
                TrackingState.TEMPORARILY_LOST,
                -> TrackingState.TRACKING
                TrackingState.UNDETECTED,
                TrackingState.CANDIDATE,
                -> if (consecutiveDetections >= detectionsRequired) {
                    TrackingState.TRACKING
                } else {
                    TrackingState.CANDIDATE
                }
            }
        } else {
            consecutiveDetections = 0
            state = when (state) {
                TrackingState.TRACKING -> {
                    lostAtMs = timestampMs
                    TrackingState.TEMPORARILY_LOST
                }
                TrackingState.TEMPORARILY_LOST -> {
                    if (timestampMs - (lostAtMs ?: timestampMs) >= lossTimeoutMs) {
                        lostAtMs = null
                        TrackingState.UNDETECTED
                    } else {
                        TrackingState.TEMPORARILY_LOST
                    }
                }
                else -> TrackingState.UNDETECTED
            }
        }
        return state
    }
}
