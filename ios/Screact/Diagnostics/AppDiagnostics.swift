import Foundation
import os

/// Lightweight telemetry, gated by the in-app debug-mode setting. Port of Android's AppDiagnostics
/// (trimmed: keeps events/counters/gauges/metrics/sampled and the text/JSONL formatters).
struct DiagnosticEvent {
    let timestampMs: Int64
    let category: String
    let name: String
    let fields: [String: String]
}

struct MetricSummary {
    let samples: Int
    let average: Double
    let p50: Double
    let p95: Double
}

struct DiagnosticSnapshot {
    let events: [DiagnosticEvent]
    let counters: [String: Int64]
    let gauges: [String: String]
    let metrics: [String: MetricSummary]
}

final class AppDiagnostics {
    static let shared = AppDiagnostics()

    private let queue = DispatchQueue(label: "com.nxtend.team35.yubiboard.diagnostics")
    private let logger = Logger(subsystem: "com.nxtend.team35.yubiboard", category: "YubiBoardDiag")
    private let maxEvents = 500
    private let maxMetricSamples = 300
    private let sampleIntervalMs: Int64 = 1_000

    private var events: [DiagnosticEvent] = []
    private var counters: [String: Int64] = [:]
    private var gauges: [String: String] = [:]
    private var metrics: [String: [Double]] = [:]
    private var lastSamples: [String: Int64] = [:]
    private var enabled = false

    func setEnabled(_ value: Bool) {
        queue.sync { enabled = value }
        if value { event("app", "debug_mode_enabled") }
    }

    var isEnabled: Bool { queue.sync { enabled } }

    func event(_ category: String, _ name: String, _ fields: [String: Any?] = [:]) {
        queue.sync {
            guard enabled else { return }
            let normalized = fields.mapValues { value -> String in
                guard let value = value else { return "" }
                return String(describing: value)
            }
            let item = DiagnosticEvent(timestampMs: Self.monotonicMs(), category: category, name: name, fields: normalized)
            events.append(item)
            if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
            logger.info("\(category)/\(name)")
        }
    }

    func sampled(_ key: String, _ category: String, _ name: String, _ fields: [String: Any?] = [:]) {
        let shouldEmit: Bool = queue.sync {
            guard enabled else { return false }
            let now = Self.monotonicMs()
            if let previous = lastSamples[key], now - previous < sampleIntervalMs { return false }
            lastSamples[key] = now
            return true
        }
        if shouldEmit { event(category, name, fields) }
    }

    func increment(_ name: String, _ amount: Int64 = 1) {
        queue.sync {
            guard enabled else { return }
            counters[name, default: 0] += amount
        }
    }

    func gauge(_ name: String, _ value: Any?) {
        queue.sync {
            guard enabled else { return }
            gauges[name] = value.map { String(describing: $0) } ?? ""
        }
    }

    func metric(_ name: String, _ value: Double) {
        queue.sync {
            guard enabled else { return }
            metrics[name, default: []].append(value)
            if metrics[name]!.count > maxMetricSamples {
                metrics[name]!.removeFirst(metrics[name]!.count - maxMetricSamples)
            }
        }
    }

    func snapshot() -> DiagnosticSnapshot {
        queue.sync {
            DiagnosticSnapshot(
                events: events,
                counters: counters,
                gauges: gauges,
                metrics: metrics.mapValues { Self.summarize($0) }
            )
        }
    }

    func clear() {
        queue.sync {
            events.removeAll()
            counters.removeAll()
            gauges.removeAll()
            metrics.removeAll()
            lastSamples.removeAll()
        }
    }

    private static func summarize(_ values: [Double]) -> MetricSummary {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(max(Int(Double(sorted.count) * fraction), 0), sorted.count - 1)
            return sorted[index]
        }
        return MetricSummary(
            samples: sorted.count,
            average: sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count),
            p50: percentile(0.50),
            p95: percentile(0.95)
        )
    }

    static func monotonicMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
