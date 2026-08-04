package com.nxtend.team35.yubiboard.vision

import org.junit.Assert.assertEquals
import org.junit.Test

class TrackingStateMachineTest {
    @Test
    fun `requires three detections before tracking`() {
        val machine = TrackingStateMachine()

        assertEquals(TrackingState.CANDIDATE, machine.update(true, 0))
        assertEquals(TrackingState.CANDIDATE, machine.update(true, 33))
        assertEquals(TrackingState.TRACKING, machine.update(true, 66))
    }

    @Test
    fun `recovers from short loss but expires long loss`() {
        val machine = TrackingStateMachine()
        repeat(3) { machine.update(true, it * 33L) }

        assertEquals(TrackingState.TEMPORARILY_LOST, machine.update(false, 100))
        assertEquals(TrackingState.TRACKING, machine.update(true, 200))
        assertEquals(TrackingState.TEMPORARILY_LOST, machine.update(false, 300))
        assertEquals(TrackingState.UNDETECTED, machine.update(false, 600))
    }

    @Test
    fun `candidate returns directly to undetected`() {
        val machine = TrackingStateMachine()

        machine.update(true, 0)
        assertEquals(TrackingState.UNDETECTED, machine.update(false, 33))
    }
}
