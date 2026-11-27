package com.nxtend.team35.yubiboard.diagnostics

import android.util.Log

/**
 * 手指フレームのAndroid内遅延を集計し、一定間隔でlogcatへ1行出す。
 * 既定で有効。記録は固定長バッファへの書き込みだけで、整形は出力時にだけ行う。
 * 時刻は同一プロセスの単調時計 [System.nanoTime] で、他端末の時計とは比べない。
 */
object PerfMonitor {
    const val LOG_TAG = "ScreactPerf"
    private const val REPORT_INTERVAL_NANOS = 5_000_000_000L

    private val window = PerfWindow()
    private var windowStartNanos = 0L

    @Volatile
    var enabled: Boolean = true

    fun now(): Long = System.nanoTime()

    @Synchronized
    fun setMaxHands(value: Int) {
        if (value != window.maxHands) {
            window.setMaxHands(value)
            windowStartNanos = now()
        }
    }

    @Synchronized
    fun onCapture(nowNanos: Long) {
        if (!enabled) return
        window.onCapture(nowNanos)
        maybeReport(nowNanos)
    }

    @Synchronized
    fun onInference(captureNanos: Long, nowNanos: Long, handCount: Int) {
        if (!enabled) return
        window.onInference(captureNanos, nowNanos, handCount)
    }

    @Synchronized
    fun onEnqueue(inferenceNanos: Long, nowNanos: Long, replacedUnsent: Boolean) {
        if (!enabled) return
        window.onEnqueue(inferenceNanos, nowNanos, replacedUnsent)
    }

    @Synchronized
    fun onSent(captureNanos: Long, enqueueNanos: Long, nowNanos: Long) {
        if (!enabled) return
        window.onSent(captureNanos, enqueueNanos, nowNanos)
    }

    private fun maybeReport(nowNanos: Long) {
        if (windowStartNanos == 0L) {
            windowStartNanos = nowNanos
            return
        }
        val elapsed = nowNanos - windowStartNanos
        if (elapsed < REPORT_INTERVAL_NANOS) return
        val line = PerfWindow.format(window.summarize(elapsed))
        window.reset()
        windowStartNanos = nowNanos
        // android.util.Log はローカルJVMテストでは使えない。
        runCatching { Log.i(LOG_TAG, line) }
    }
}
