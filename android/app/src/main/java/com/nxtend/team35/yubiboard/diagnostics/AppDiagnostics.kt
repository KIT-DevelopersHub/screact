package com.nxtend.team35.yubiboard.diagnostics

import android.util.Log
import com.nxtend.team35.yubiboard.BuildConfig
import java.util.ArrayDeque
import java.util.Locale

data class DiagnosticEvent(
    val timestampMs: Long,
    val category: String,
    val name: String,
    val fields: Map<String, String> = emptyMap(),
)

data class DiagnosticSnapshot(
    val events: List<DiagnosticEvent>,
    val counters: Map<String, Long>,
    val gauges: Map<String, String>,
    val metrics: Map<String, MetricSummary>,
)

data class MetricSummary(
    val samples: Int,
    val average: Double,
    val p50: Double,
    val p95: Double,
)

/** Lightweight telemetry controlled by the persisted in-app debug-mode setting. */
object AppDiagnostics {
    private const val LOG_TAG = "YubiBoardDiag"
    private const val MAX_EVENTS = 500
    private const val SAMPLE_INTERVAL_MS = 1_000L
    private val events = ArrayDeque<DiagnosticEvent>()
    private val counters = linkedMapOf<String, Long>()
    private val gauges = linkedMapOf<String, String>()
    private val metrics = linkedMapOf<String, ArrayDeque<Double>>()
    private val lastSamples = mutableMapOf<String, Long>()
    @Volatile
    private var enabled = BuildConfig.DEBUG

    fun setEnabled(value: Boolean) {
        enabled = value
        if (value) event("app", "debug_mode_enabled")
    }

    fun isEnabled(): Boolean = enabled

    @Synchronized
    fun event(category: String, name: String, fields: Map<String, Any?> = emptyMap()) {
        if (!enabled) return
        val normalized = fields.mapValues { (_, value) -> value?.toString().orEmpty() }
        val item = DiagnosticEvent(monotonicMs(), category, name, normalized)
        events.addLast(item)
        while (events.size > MAX_EVENTS) events.removeFirst()
        // android.util.Log is not implemented by local JVM tests.
        runCatching { Log.i(LOG_TAG, item.toJsonLine()) }
    }

    @Synchronized
    fun sampled(key: String, category: String, name: String, fields: Map<String, Any?> = emptyMap()) {
        if (!enabled) return
        val now = monotonicMs()
        val previous = lastSamples[key]
        if (previous != null && now - previous < SAMPLE_INTERVAL_MS) return
        lastSamples[key] = now
        event(category, name, fields)
    }

    @Synchronized
    fun increment(name: String, amount: Long = 1) {
        if (!enabled) return
        counters[name] = (counters[name] ?: 0L) + amount
    }

    @Synchronized
    fun gauge(name: String, value: Any?) {
        if (!enabled) return
        gauges[name] = value?.toString().orEmpty()
    }

    @Synchronized
    fun metric(name: String, value: Number) {
        if (!enabled) return
        val values = metrics.getOrPut(name) { ArrayDeque() }
        values.addLast(value.toDouble())
        while (values.size > MAX_METRIC_SAMPLES) values.removeFirst()
    }

    @Synchronized
    fun snapshot(): DiagnosticSnapshot = DiagnosticSnapshot(
        events = events.toList(),
        counters = counters.toMap(),
        gauges = gauges.toMap(),
        metrics = metrics.mapValues { (_, values) -> values.summarize() },
    )

    @Synchronized
    fun clear() {
        events.clear()
        counters.clear()
        gauges.clear()
        metrics.clear()
        lastSamples.clear()
    }

    fun format(snapshot: DiagnosticSnapshot = snapshot()): String = buildString {
        appendLine("YubiBoard debug diagnostics")
        if (snapshot.gauges.isNotEmpty()) {
            appendLine("\nLatest values")
            snapshot.gauges.forEach { (key, value) -> appendLine("$key: $value") }
        }
        if (snapshot.counters.isNotEmpty()) {
            appendLine("\nCounters")
            snapshot.counters.forEach { (key, value) -> appendLine("$key: $value") }
        }
        if (snapshot.metrics.isNotEmpty()) {
            appendLine("\nRolling metrics")
            snapshot.metrics.forEach { (key, value) ->
                appendLine(
                    "$key: n=${value.samples} avg=${"%.2f".format(Locale.US, value.average)} " +
                        "p50=${"%.2f".format(Locale.US, value.p50)} p95=${"%.2f".format(Locale.US, value.p95)}",
                )
            }
        }
        appendLine("\nRecent events")
        snapshot.events.takeLast(80).forEach { event ->
            append("${event.timestampMs} ${event.category}/${event.name}")
            if (event.fields.isNotEmpty()) {
                append(" ")
                append(event.fields.entries.joinToString { "${it.key}=${it.value}" })
            }
            appendLine()
        }
    }

    fun jsonLines(snapshot: DiagnosticSnapshot = snapshot()): String =
        snapshot.events.joinToString(separator = "\n", postfix = if (snapshot.events.isEmpty()) "" else "\n") {
            it.toJsonLine()
        }

    private fun DiagnosticEvent.toJsonLine(): String = buildString {
        append("{\"timestampMs\":")
        append(timestampMs)
        append(",\"category\":\"")
        append(category.jsonEscape())
        append("\",\"name\":\"")
        append(name.jsonEscape())
        append("\",\"fields\":{")
        append(fields.entries.joinToString { (key, value) ->
            "\"${key.jsonEscape()}\":\"${value.jsonEscape()}\""
        })
        append("}}")
    }

    private fun String.jsonEscape(): String = buildString(length) {
        this@jsonEscape.forEach { character ->
            when (character) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append(String.format(Locale.US, "\\u%04x", character.code))
                } else {
                    append(character)
                }
            }
        }
    }

    private fun monotonicMs(): Long = System.nanoTime() / 1_000_000L

    private fun Collection<Double>.summarize(): MetricSummary {
        val sorted = sorted()
        fun percentile(fraction: Double): Double {
            if (sorted.isEmpty()) return 0.0
            val index = (sorted.size * fraction).toInt().coerceIn(sorted.indices)
            return sorted[index]
        }
        return MetricSummary(
            samples = sorted.size,
            average = if (sorted.isEmpty()) 0.0 else sorted.average(),
            p50 = percentile(0.50),
            p95 = percentile(0.95),
        )
    }

    private const val MAX_METRIC_SAMPLES = 300
}
