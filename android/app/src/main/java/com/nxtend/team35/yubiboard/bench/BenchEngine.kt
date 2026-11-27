package com.nxtend.team35.yubiboard.bench

import com.nxtend.team35.yubiboard.network.ble.BenchProtocol
import com.nxtend.team35.yubiboard.network.ble.BenchStats
import com.nxtend.team35.yubiboard.network.ble.SyntheticHandFrames
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** 計測で使う経路。send* は 1 単位の送信が終わるまで（BLE なら onNotificationSent まで）戻らない。 */
interface BenchTransport {
    /** 1 単位で送れるフレームの最大バイト数。 */
    fun maxUnitBytes(): Int
    fun sendFrameUnit(bytes: ByteArray): Boolean
    fun sendControl(bytes: ByteArray): Boolean
    /** STATS に載せる MTU（BLE 以外は 0）。 */
    fun mtu(): Int = 0
}

/**
 * 計測の送信側。生成スレッドが fps でフレームを作って 1 枠の送信待ちに置き（最新優先）、
 * 送信スレッドが制御応答を優先して 1 単位ずつ送る。本番の送信経路とは独立している。
 */
class BenchEngine(
    private val transport: BenchTransport,
    private val clockMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val log: (String) -> Unit = {},
) {
    private class Pending(val frameId: Long, val payload: ByteArray)

    private val lock = ReentrantLock()
    private val wake = lock.newCondition()
    private val controlQueue = ConcurrentLinkedQueue<ByteArray>()
    private val latest = AtomicReference<Pending?>(null)
    private val generator: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private var generatorTask: ScheduledFuture<*>? = null
    @Volatile private var running = true
    @Volatile private var stats = BenchStats()
    private var nextFrameId = 0L
    private val sender = Thread(::senderLoop, "bench-sender").apply { isDaemon = true }

    fun start() {
        sender.start()
    }

    /** 制御の書き込みを受け取ったときに呼ぶ。応答は送信スレッドから送る。 */
    fun onControl(bytes: ByteArray) {
        when (val command = BenchProtocol.parseCommand(bytes)) {
            is BenchProtocol.Command.Ping -> enqueueControl(BenchProtocol.pong(command.seq))
            is BenchProtocol.Command.Start -> {
                startStream(command)
                enqueueControl(BenchProtocol.ack())
            }
            BenchProtocol.Command.Stop -> {
                stopStream()
                enqueueControl(BenchProtocol.stats(stats, transport.mtu()))
            }
            null -> log("unknown control: ${bytes.size} B")
        }
    }

    fun snapshot(): BenchStats = stats

    fun shutdown() {
        running = false
        stopStream()
        generator.shutdownNow()
        lock.withLock { wake.signalAll() }
        sender.interrupt()
    }

    private fun startStream(command: BenchProtocol.Command.Start) {
        stopStream()
        stats = BenchStats()
        latest.set(null)
        nextFrameId = 0L
        log("start hands=${command.hands} fps=${command.fps} kind=${command.payloadKind}")
        val periodNanos = 1_000_000_000L / command.fps
        generatorTask = generator.scheduleAtFixedRate({
            val frameId = ++nextFrameId
            val now = clockMs()
            val payload = if (command.payloadKind == BenchProtocol.PAYLOAD_JSON) {
                SyntheticHandFrames.json(frameId, now, command.hands)
            } else {
                SyntheticHandFrames.binary(frameId, now, command.hands)
            }
            val replaced = latest.getAndSet(Pending(frameId, payload)) != null
            update { it.copy(generated = it.generated + 1, replacedUnsent = it.replacedUnsent + if (replaced) 1 else 0) }
            lock.withLock { wake.signalAll() }
        }, 0L, periodNanos, TimeUnit.NANOSECONDS)
    }

    private fun stopStream() {
        generatorTask?.cancel(false)
        generatorTask = null
        latest.set(null)
    }

    private fun enqueueControl(bytes: ByteArray) {
        controlQueue.add(bytes)
        lock.withLock { wake.signalAll() }
    }

    @Synchronized
    private fun update(transform: (BenchStats) -> BenchStats) {
        stats = transform(stats)
    }

    private fun senderLoop() {
        var units: List<ByteArray> = emptyList()
        var unitIndex = 0
        var currentBytes = 0
        while (running) {
            try {
                val control = controlQueue.poll()
                if (control != null) {
                    transport.sendControl(control)
                    continue
                }
                if (unitIndex >= units.size) {
                    val pending = latest.getAndSet(null)
                    if (pending == null) {
                        lock.withLock {
                            if (controlQueue.isEmpty() && latest.get() == null) {
                                wake.await(50, TimeUnit.MILLISECONDS)
                            }
                        }
                        continue
                    }
                    units = BenchProtocol.split(pending.frameId, pending.payload, transport.maxUnitBytes())
                    unitIndex = 0
                    currentBytes = pending.payload.size
                }
                val ok = transport.sendFrameUnit(units[unitIndex])
                unitIndex++
                if (!ok) {
                    // 分割途中で失敗したら、そのフレームの残りは送らない。
                    update { it.copy(unitFailures = it.unitFailures + 1) }
                    unitIndex = units.size
                    continue
                }
                update { it.copy(unitsSent = it.unitsSent + 1) }
                if (unitIndex == units.size) {
                    update { it.copy(framesSent = it.framesSent + 1, payloadBytesSent = it.payloadBytesSent + currentBytes) }
                }
            } catch (_: InterruptedException) {
                return
            } catch (error: RuntimeException) {
                log("sender error: ${error.message}")
            }
        }
    }
}
