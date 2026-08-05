package com.nxtend.team35.yubiboard.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AppDiagnosticsTest {
    @Before
    fun reset() {
        AppDiagnostics.setEnabled(true)
        AppDiagnostics.clear()
    }

    @Test
    fun `records counters gauges and bounded events`() {
        AppDiagnostics.increment("frames", 2)
        AppDiagnostics.gauge("mode", "tracking")
        listOf(1, 2, 3, 4, 100).forEach { AppDiagnostics.metric("latency", it) }
        repeat(520) { AppDiagnostics.event("test", "frame", mapOf("id" to it)) }

        val snapshot = AppDiagnostics.snapshot()
        assertEquals(2L, snapshot.counters["frames"])
        assertEquals("tracking", snapshot.gauges["mode"])
        assertEquals(500, snapshot.events.size)
        assertEquals(5, snapshot.metrics.getValue("latency").samples)
        assertEquals(3.0, snapshot.metrics.getValue("latency").p50, 0.0)
        assertEquals(100.0, snapshot.metrics.getValue("latency").p95, 0.0)
        assertTrue(AppDiagnostics.jsonLines(snapshot).contains("\"id\":\"519\""))
    }

    @Test
    fun `sampled records the first event and suppresses an immediate duplicate`() {
        AppDiagnostics.sampled("hand", "vision", "hand_result")
        AppDiagnostics.sampled("hand", "vision", "hand_result")

        assertEquals(1, AppDiagnostics.snapshot().events.size)
    }

    @Test
    fun `disabled mode does not collect diagnostics`() {
        AppDiagnostics.setEnabled(false)

        AppDiagnostics.event("test", "hidden")
        AppDiagnostics.increment("frames")
        AppDiagnostics.gauge("mode", "tracking")
        AppDiagnostics.metric("latency", 10)

        val snapshot = AppDiagnostics.snapshot()
        assertTrue(snapshot.events.isEmpty())
        assertTrue(snapshot.counters.isEmpty())
        assertTrue(snapshot.gauges.isEmpty())
        assertTrue(snapshot.metrics.isEmpty())
    }
}
