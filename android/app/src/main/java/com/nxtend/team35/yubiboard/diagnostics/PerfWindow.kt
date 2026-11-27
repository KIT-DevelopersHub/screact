package com.nxtend.team35.yubiboard.diagnostics

import java.util.Locale

/**
 * 固定長のLongリングバッファ。満杯なら最古の値を上書きする。
 * 追加時に割り当てを行わず、統計は [percentile] でまとめて計算する。
 */
class LongSampleBuffer(val capacity: Int) {
    private val values = LongArray(capacity)
    private val scratch = LongArray(capacity)
    private var next = 0

    /** 保持中のサンプル数（最大 [capacity]）。 */
    var size = 0
        private set

    init {
        require(capacity > 0)
    }

    fun add(value: Long) {
        values[next] = value
        next = (next + 1) % capacity
        if (size < capacity) size++
    }

    fun clear() {
        next = 0
        size = 0
    }

    /**
     * 最近傍順位法の百分位数。fraction=0.5 は中央値（偶数個なら下側）、0.95 はP95。
     * サンプルが無ければ null。
     */
    fun percentile(fraction: Double): Long? {
        if (size == 0) return null
        // 満杯でない間は values[0 until size] が有効、満杯なら全要素が有効。
        System.arraycopy(values, 0, scratch, 0, size)
        scratch.sort(0, size)
        return nearestRank(scratch, size, fraction)
    }

    companion object {
        fun nearestRank(sorted: LongArray, count: Int, fraction: Double): Long {
            require(count in 1..sorted.size)
            require(fraction > 0.0 && fraction <= 1.0)
            val rank = kotlin.math.ceil(fraction * count).toInt().coerceIn(1, count)
            return sorted[rank - 1]
        }
    }
}

/** 区間ごとの中央値とP95（ナノ秒）。 */
data class SegmentSummary(val samples: Int, val p50Nanos: Long?, val p95Nanos: Long?)

data class PerfSummary(
    val windowNanos: Long,
    val maxHands: Int,
    val framesCaptured: Long,
    val inferenceResults: Long,
    val enqueued: Long,
    val sent: Long,
    /** 送信前に新しいフレームで上書きされ、送られなかったフレーム数。 */
    val droppedInQueue: Long,
    /** MediaPipeへ渡したが結果が返らなかったフレーム数（窓内の概算）。 */
    val droppedInInference: Long,
    /** 検出した手の数ごとの結果数。添字 0, 1, 2。 */
    val handCounts: List<Long>,
    val frameInterval: SegmentSummary,
    val captureToInference: SegmentSummary,
    val inferenceToEnqueue: SegmentSummary,
    val enqueueToSend: SegmentSummary,
    val captureToSend: SegmentSummary,
)

/**
 * Android内の1フレームの各区間を集計する窓。時刻はすべて同一端末の単調時計（ナノ秒）。
 * スレッド安全ではないため、呼び出し側で同期する。
 *
 * 区間:
 * - capture: 解析スレッドがカメラフレームを受け取った時刻
 * - inference: MediaPipeの結果コールバック時刻
 * - enqueue: 送信キュー（最新1件）へ入れた時刻
 * - send: WebSocketへ送信要求が受理された時刻
 */
class PerfWindow(capacity: Int = DEFAULT_CAPACITY) {
    private val frameInterval = LongSampleBuffer(capacity)
    private val captureToInference = LongSampleBuffer(capacity)
    private val inferenceToEnqueue = LongSampleBuffer(capacity)
    private val enqueueToSend = LongSampleBuffer(capacity)
    private val captureToSend = LongSampleBuffer(capacity)
    private val handCounts = LongArray(3)
    private var framesCaptured = 0L
    private var inferenceResults = 0L
    private var enqueued = 0L
    private var sent = 0L
    private var droppedInQueue = 0L
    private var lastCaptureNanos = 0L

    var maxHands: Int = 1
        private set

    /** 手の数の設定を変えたら、混ざらないよう窓を捨てる。 */
    fun setMaxHands(value: Int) {
        if (value == maxHands) return
        maxHands = value
        reset()
        lastCaptureNanos = 0L
    }

    fun onCapture(nowNanos: Long) {
        framesCaptured++
        val previous = lastCaptureNanos
        lastCaptureNanos = nowNanos
        if (previous == 0L) return
        val interval = nowNanos - previous
        // 位置合わせモードからの復帰などの長い空白はフレーム間隔に含めない。
        if (interval in 0..MAX_FRAME_GAP_NANOS) frameInterval.add(interval)
    }

    fun onInference(captureNanos: Long, nowNanos: Long, handCount: Int) {
        inferenceResults++
        handCounts[handCount.coerceIn(0, handCounts.size - 1)]++
        addSegment(captureToInference, captureNanos, nowNanos)
    }

    fun onEnqueue(inferenceNanos: Long, nowNanos: Long, replacedUnsent: Boolean) {
        enqueued++
        if (replacedUnsent) droppedInQueue++
        addSegment(inferenceToEnqueue, inferenceNanos, nowNanos)
    }

    fun onSent(captureNanos: Long, enqueueNanos: Long, nowNanos: Long) {
        sent++
        addSegment(enqueueToSend, enqueueNanos, nowNanos)
        addSegment(captureToSend, captureNanos, nowNanos)
    }

    fun summarize(windowNanos: Long): PerfSummary = PerfSummary(
        windowNanos = windowNanos,
        maxHands = maxHands,
        framesCaptured = framesCaptured,
        inferenceResults = inferenceResults,
        enqueued = enqueued,
        sent = sent,
        droppedInQueue = droppedInQueue,
        droppedInInference = (framesCaptured - inferenceResults).coerceAtLeast(0),
        handCounts = handCounts.toList(),
        frameInterval = frameInterval.summary(),
        captureToInference = captureToInference.summary(),
        inferenceToEnqueue = inferenceToEnqueue.summary(),
        enqueueToSend = enqueueToSend.summary(),
        captureToSend = captureToSend.summary(),
    )

    /** 集計値を消す。フレーム間隔の基準時刻は連続性のため残す。 */
    fun reset() {
        frameInterval.clear()
        captureToInference.clear()
        inferenceToEnqueue.clear()
        enqueueToSend.clear()
        captureToSend.clear()
        handCounts.fill(0)
        framesCaptured = 0
        inferenceResults = 0
        enqueued = 0
        sent = 0
        droppedInQueue = 0
    }

    private fun addSegment(buffer: LongSampleBuffer, startNanos: Long, endNanos: Long) {
        // 時刻が無い（疑似入力など）か逆転した値は捨てる。
        if (startNanos <= 0L || endNanos < startNanos) return
        buffer.add(endNanos - startNanos)
    }

    private fun LongSampleBuffer.summary() =
        SegmentSummary(size, percentile(0.5), percentile(0.95))

    companion object {
        const val DEFAULT_CAPACITY = 512
        const val MAX_FRAME_GAP_NANOS = 2_000_000_000L

        /**
         * logcat 1行分の文字列。区間は「中央値/P95」をミリ秒で表す。
         * 例: win=5.0s maxHands=2 cap=148 inf=146 enq=146 sent=98 dropQ=48 dropInf=2 hands=10/60/76 ...
         */
        fun format(summary: PerfSummary): String = buildString {
            append("win=").append(seconds(summary.windowNanos)).append('s')
            append(" maxHands=").append(summary.maxHands)
            append(" cap=").append(summary.framesCaptured)
            append(" inf=").append(summary.inferenceResults)
            append(" enq=").append(summary.enqueued)
            append(" sent=").append(summary.sent)
            append(" dropQ=").append(summary.droppedInQueue)
            append(" dropInf=").append(summary.droppedInInference)
            append(" hands=").append(summary.handCounts.joinToString("/"))
            appendSegment("interval", summary.frameInterval)
            appendSegment("capInf", summary.captureToInference)
            appendSegment("infEnq", summary.inferenceToEnqueue)
            appendSegment("enqSend", summary.enqueueToSend)
            appendSegment("capSend", summary.captureToSend)
        }

        private fun StringBuilder.appendSegment(name: String, segment: SegmentSummary) {
            append(' ').append(name).append('=')
            append(millis(segment.p50Nanos)).append('/').append(millis(segment.p95Nanos))
        }

        private fun millis(nanos: Long?): String =
            nanos?.let { String.format(Locale.US, "%.1f", it / 1_000_000.0) } ?: "-"

        private fun seconds(nanos: Long): String =
            String.format(Locale.US, "%.1f", nanos / 1_000_000_000.0)
    }
}

/**
 * MediaPipeの入力時刻（ミリ秒キー）から撮影時刻（ナノ秒）を引く小さな固定表。
 * 非同期推論の結果を元フレームへ結び付けるために使い、毎フレームの割り当てを避ける。
 */
class TimestampStampTable(capacity: Int = 16) {
    private val keys = LongArray(capacity) { EMPTY }
    private val values = LongArray(capacity)
    private var next = 0

    @Synchronized
    fun put(key: Long, value: Long) {
        keys[next] = key
        values[next] = value
        next = (next + 1) % keys.size
    }

    /** 見つかれば値を返して消す。無ければ 0。 */
    @Synchronized
    fun take(key: Long): Long {
        for (index in keys.indices) {
            if (keys[index] == key) {
                keys[index] = EMPTY
                return values[index]
            }
        }
        return 0L
    }

    @Synchronized
    fun remove(key: Long) {
        take(key)
    }

    @Synchronized
    fun clear() {
        keys.fill(EMPTY)
        next = 0
    }

    private companion object {
        const val EMPTY = Long.MIN_VALUE
    }
}
