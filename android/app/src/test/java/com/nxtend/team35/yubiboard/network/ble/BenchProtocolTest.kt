package com.nxtend.team35.yubiboard.network.ble

import com.nxtend.team35.yubiboard.bench.BenchEngine
import com.nxtend.team35.yubiboard.bench.BenchTransport
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class BenchProtocolTest {
    @Test
    fun parsesCommands() {
        assertEquals(BenchProtocol.Command.Ping(0xFFFFFFFEL), BenchProtocol.parseCommand(byteArrayOf(1, -2, -1, -1, -1)))
        assertEquals(BenchProtocol.Command.Start(2, 30, 0), BenchProtocol.parseCommand(byteArrayOf(2, 2, 30, 0)))
        assertEquals(BenchProtocol.Command.Stop, BenchProtocol.parseCommand(byteArrayOf(3)))
        assertNull(BenchProtocol.parseCommand(byteArrayOf(2, 3, 30, 0)))
        assertNull(BenchProtocol.parseCommand(byteArrayOf(1, 0)))
        assertNull(BenchProtocol.parseCommand(byteArrayOf()))
    }

    @Test
    fun pongEchoesSequence() {
        assertArrayEquals(byteArrayOf(0x81.toByte(), 4, 3, 2, 1), BenchProtocol.pong(0x01020304))
    }

    @Test
    fun smallPayloadIsNotSplit() {
        val payload = ByteArray(244) { it.toByte() }
        val units = BenchProtocol.split(9, payload, 244)
        assertEquals(1, units.size)
        assertArrayEquals(payload, units[0])
    }

    @Test
    fun largePayloadIsSplitAndReassembles() {
        val payload = ByteArray(2000) { (it * 7).toByte() }
        val units = BenchProtocol.split(0x0A0B0C0DL, payload, 244)
        assertEquals(9, units.size) // 237 B × 8 + 104 B
        units.forEachIndexed { index, unit ->
            assertTrue(unit.size <= 244)
            val buffer = ByteBuffer.wrap(unit).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(BenchProtocol.FRAGMENT_MAGIC, buffer.get())
            assertEquals(0x0A0B0C0D, buffer.int)
            assertEquals(index, buffer.get().toInt())
            assertEquals(9, buffer.get().toInt())
        }
        val joined = units.flatMap { it.drop(BenchProtocol.FRAGMENT_HEADER_BYTES) }.toByteArray()
        assertArrayEquals(payload, joined)
    }

    @Test
    fun syntheticFramesHaveExpectedSizes() {
        assertEquals(148, SyntheticHandFrames.binary(1, 0, 1).size)
        assertEquals(278, SyntheticHandFrames.binary(1, 0, 2).size)
        val json = String(SyntheticHandFrames.json(1, 0, 1), Charsets.UTF_8)
        assertTrue(json.startsWith("{"))
        assertTrue(json.contains("\"frameId\":1"))
        assertTrue("JSON 1 hand is ~2 KB: ${json.length}", json.length in 1500..2600)
    }
}

class BenchEngineTest {
    private class FakeTransport(private val unit: Int) : BenchTransport {
        val frames = CopyOnWriteArrayList<ByteArray>()
        val controls = CopyOnWriteArrayList<ByteArray>()
        val stats = CountDownLatch(1)
        override fun maxUnitBytes() = unit
        override fun sendFrameUnit(bytes: ByteArray): Boolean = frames.add(bytes)
        override fun sendControl(bytes: ByteArray): Boolean {
            controls.add(bytes)
            if (bytes[0] == BenchProtocol.RSP_STATS) stats.countDown()
            return true
        }
        override fun mtu() = unit + 3
    }

    @Test
    fun streamsFramesAndReportsStats() {
        val transport = FakeTransport(244)
        val engine = BenchEngine(transport)
        engine.start()
        try {
            engine.onControl(byteArrayOf(1, 5, 0, 0, 0))
            engine.onControl(byteArrayOf(2, 2, 100, 0))
            Thread.sleep(300)
            engine.onControl(byteArrayOf(3))
            assertTrue(transport.stats.await(2, TimeUnit.SECONDS))
        } finally {
            engine.shutdown()
        }
        assertArrayEquals(BenchProtocol.pong(5), transport.controls[0])
        val statsBytes = ByteBuffer.wrap(transport.controls.last()).order(ByteOrder.LITTLE_ENDIAN)
        statsBytes.get()
        val generated = statsBytes.int
        val framesSent = statsBytes.int
        val replaced = statsBytes.int
        val unitsSent = statsBytes.int
        assertTrue(generated > 5)
        // STOP 時点の送信待ち・送信中のフレームはどちらにも数えない。
        assertTrue(generated - framesSent - replaced in 0..2)
        // 278 B は 244 B 単位に収まらないので 2 単位に分かれる（送信中の 1 単位を許す）。
        assertTrue(unitsSent - framesSent * 2 in 0..1)
        statsBytes.int
        assertEquals(framesSent * 278, statsBytes.int)
        assertEquals(247, statsBytes.short.toInt())
        assertTrue(transport.frames.all { it[0] == BenchProtocol.FRAGMENT_MAGIC })
    }
}
