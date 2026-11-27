package com.nxtend.team35.yubiboard.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PerfWindowTest {
    private val ms = 1_000_000L

    @Test
    fun `percentile uses nearest rank`() {
        val buffer = LongSampleBuffer(100)
        (1L..100L).shuffled(kotlin.random.Random(1)).forEach(buffer::add)

        assertEquals(50L, buffer.percentile(0.5))
        assertEquals(95L, buffer.percentile(0.95))
        assertEquals(100L, buffer.percentile(1.0))
    }

    @Test
    fun `median of even count is lower middle and small sets are stable`() {
        val buffer = LongSampleBuffer(8)
        listOf(40L, 10L, 30L, 20L).forEach(buffer::add)

        assertEquals(20L, buffer.percentile(0.5))
        assertEquals(40L, buffer.percentile(0.95))

        val single = LongSampleBuffer(4)
        single.add(7L)
        assertEquals(7L, single.percentile(0.5))
        assertEquals(7L, single.percentile(0.95))
    }

    @Test
    fun `empty buffer has no percentile`() {
        assertNull(LongSampleBuffer(4).percentile(0.5))
    }

    @Test
    fun `ring buffer keeps only latest samples`() {
        val buffer = LongSampleBuffer(4)
        (1L..10L).forEach(buffer::add)

        assertEquals(4, buffer.size)
        assertEquals(8L, buffer.percentile(0.5))
        assertEquals(10L, buffer.percentile(0.95))

        buffer.clear()
        assertEquals(0, buffer.size)
        assertNull(buffer.percentile(0.5))
    }

    @Test
    fun `tracks segments drops and hand counts per frame`() {
        val window = PerfWindow()
        // 3フレーム撮影。2枚目は送信前に3枚目で上書きされる。
        var t = 1_000 * ms
        val captures = LongArray(3)
        for (index in 0 until 3) {
            captures[index] = t
            window.onCapture(t)
            window.onInference(t, t + 20 * ms, handCount = index)
            window.onEnqueue(t + 20 * ms, t + 21 * ms, replacedUnsent = index == 2)
            t += 33 * ms
        }
        window.onSent(captures[0], captures[0] + 21 * ms, captures[0] + 25 * ms)
        window.onSent(captures[2], captures[2] + 21 * ms, captures[2] + 31 * ms)

        val summary = window.summarize(5_000 * ms)

        assertEquals(3L, summary.framesCaptured)
        assertEquals(3L, summary.inferenceResults)
        assertEquals(3L, summary.enqueued)
        assertEquals(2L, summary.sent)
        assertEquals(1L, summary.droppedInQueue)
        assertEquals(0L, summary.droppedInInference)
        assertEquals(listOf(1L, 1L, 1L), summary.handCounts)
        assertEquals(2, summary.frameInterval.samples)
        assertEquals(33 * ms, summary.frameInterval.p50Nanos)
        assertEquals(20 * ms, summary.captureToInference.p50Nanos)
        assertEquals(1 * ms, summary.inferenceToEnqueue.p95Nanos)
        assertEquals(4 * ms, summary.enqueueToSend.p50Nanos)
        assertEquals(10 * ms, summary.enqueueToSend.p95Nanos)
        assertEquals(25 * ms, summary.captureToSend.p50Nanos)
        assertEquals(31 * ms, summary.captureToSend.p95Nanos)
    }

    @Test
    fun `counts frames without inference result as inference drops`() {
        val window = PerfWindow()
        window.onCapture(1 * ms)
        window.onCapture(34 * ms)
        window.onInference(1 * ms, 20 * ms, 1)

        assertEquals(1L, window.summarize(1).droppedInInference)
    }

    @Test
    fun `ignores missing timestamps and long gaps`() {
        val window = PerfWindow()
        window.onCapture(1_000 * ms)
        window.onCapture(5_000 * ms) // 位置合わせ後の再開などの長い空白
        window.onInference(0L, 5_020 * ms, 1) // 疑似入力など撮影時刻なし
        window.onEnqueue(5_020 * ms, 5_010 * ms, replacedUnsent = false) // 逆転

        val summary = window.summarize(1)
        assertEquals(0, summary.frameInterval.samples)
        assertEquals(0, summary.captureToInference.samples)
        assertEquals(0, summary.inferenceToEnqueue.samples)
        assertEquals(1L, summary.inferenceResults)
    }

    @Test
    fun `reset clears counters but keeps frame interval continuity`() {
        val window = PerfWindow()
        window.onCapture(100 * ms)
        window.onEnqueue(100 * ms, 101 * ms, replacedUnsent = true)
        window.reset()
        window.onCapture(133 * ms)

        val summary = window.summarize(1)
        assertEquals(1L, summary.framesCaptured)
        assertEquals(0L, summary.droppedInQueue)
        assertEquals(33 * ms, summary.frameInterval.p50Nanos)
    }

    @Test
    fun `changing max hands starts a fresh window`() {
        val window = PerfWindow()
        window.onCapture(100 * ms)
        window.onInference(100 * ms, 120 * ms, 1)
        window.setMaxHands(2)
        window.onCapture(133 * ms)

        val summary = window.summarize(1)
        assertEquals(2, summary.maxHands)
        assertEquals(1L, summary.framesCaptured)
        assertEquals(0L, summary.inferenceResults)
        assertEquals(0, summary.frameInterval.samples)
    }

    @Test
    fun `formats one log line with median and p95 in milliseconds`() {
        val window = PerfWindow()
        window.setMaxHands(2)
        window.onCapture(1_000 * ms)
        window.onCapture(1_033 * ms)
        window.onInference(1_033 * ms, 1_051 * ms, 2)
        window.onEnqueue(1_051 * ms, 1_051 * ms + 500_000, replacedUnsent = false)
        window.onSent(1_033 * ms, 1_051 * ms + 500_000, 1_060 * ms)

        val line = PerfWindow.format(window.summarize(5_000 * ms))

        assertEquals(
            "win=5.0s maxHands=2 cap=2 inf=1 enq=1 sent=1 dropQ=0 dropInf=1 hands=0/0/1 " +
                "interval=33.0/33.0 capInf=18.0/18.0 infEnq=0.5/0.5 enqSend=8.5/8.5 capSend=27.0/27.0",
            line,
        )
        assertTrue(!line.contains('\n'))
    }

    @Test
    fun `formats missing segments as dash`() {
        val line = PerfWindow.format(PerfWindow().summarize(5_000 * ms))
        assertTrue(line.contains("capSend=-/-"))
    }

    @Test
    fun `stamp table returns value once and evicts oldest`() {
        val table = TimestampStampTable(capacity = 2)
        table.put(10L, 100L)
        table.put(11L, 110L)

        assertEquals(100L, table.take(10L))
        assertEquals(0L, table.take(10L))

        table.put(12L, 120L)
        table.put(13L, 130L) // 11 を上書き
        assertEquals(0L, table.take(11L))
        assertEquals(120L, table.take(12L))
        assertEquals(130L, table.take(13L))
    }
}
