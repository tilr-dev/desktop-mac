import AppKit
import Darwin
import WebKit

/// Compatibility entry points for the web Performance service. No separate collector or timer.
final class DebugMode {
    var settings: Config.Debug
    var recording = false
    init(settings: Config.Debug) { self.settings = settings }
    var dir: String { Config.resolve(settings.dir) }
    // Legacy launch preference seeds the shared flag only once; the web toggle remains authoritative.
    var collector: String? {
        settings.enabled ? "if (sessionStorage.getItem('tilr.performance.enabled') === null) sessionStorage.setItem('tilr.performance.enabled', 'on')" : nil
    }
    func configChanged(_ new: Config.Debug) { settings = new }
    func write(dump: [String: Any], path: String?) throws -> (path: String, summary: [String]) {
        let file = dump
        let summary = Self.summary(dump)
        let url: URL
        if let path, !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            url = URL(fileURLWithPath: dir).appendingPathComponent(format.string(from: Date()) + ".json")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        return (url.path, summary)
    }

    /// Fallback for an older Performance plugin whose `finish()` returns nothing (current ones
    /// return the recording already cut, `dropped` included).
    /// The page's `snapshot()` (up to 120 s) cut to a recording that began at `start` (page ms):
    /// `started`, `events` and `samples` from `start` on; each metric series keeps its `recent`
    /// observations with t >= start and its `seconds` buckets with second >= floor(start / 1000).
    /// A series' count / sum / min / max / last / t stay session totals (the collector keeps no
    /// per-window aggregates); `dropped` stays the snapshot's (its window, not the recording's).
    static func cut(_ dump: [String: Any], from start: Double) -> [String: Any] {
        var out = dump
        let number = { (value: Any?) in (value as? NSNumber)?.doubleValue }
        if let started = number(dump["started"]) { out["started"] = max(started, start) }
        for key in ["events", "samples"] {
            if let list = dump[key] as? [[String: Any]] { out[key] = list.filter { (number($0["t"]) ?? -.infinity) >= start } }
        }
        if let metrics = dump["metrics"] as? [[String: Any]] {
            let first = (start / 1000).rounded(.down)
            out["metrics"] = metrics.map { series -> [String: Any] in
                var series = series
                if let recent = series["recent"] as? [[Any]] {
                    series["recent"] = recent.filter { (number($0.first) ?? -.infinity) >= start }
                }
                if let seconds = series["seconds"] as? [[Any]] {
                    series["seconds"] = seconds.filter { (number($0.first) ?? -.infinity) >= first }
                }
                return series
            }
        }
        return out
    }

    /// The lines `record` prints: React counts, frames, metric series, then one line per chain and
    /// subject (pane, else window, else plugin): hops in hop order, end-to-end measures last, each
    /// the p95 in ms of the series' `recent` ring inside the recording (at most 256 latest values
    /// per series, so a busy series covers only the recording's tail, not all of it).
    static func summary(_ dump: [String: Any]) -> [String] {
        let events = dump["events"] as? [[String: Any]] ?? []
        let commits = events.filter { $0["kind"] as? String == "react" }.count
        let renders = events.filter { $0["kind"] as? String == "component" }.reduce(0) { $0 + ($1["count"] as? Int ?? 0) }
        var lines = ["Performance: \(commits) React commits, \(renders) component renders"]
        if let samples = dump["samples"] as? [[String: Any]] {
            let fps = samples.compactMap { ($0["fps"] as? NSNumber)?.doubleValue }
            lines.append("Samples: \(samples.count), FPS measured in \(fps.count)" + (fps.isEmpty ? "" : ", p50 \(format(percentile(fps, 0.5)!))"))
        }
        if let metrics = dump["metrics"] as? [[String: Any]] {
            lines.append("Metrics: \(metrics.count) series; recent (last ≤256 values, p95 below) / seconds cut to the recording, count/sum/min/max/last are session totals")
            lines += chains(metrics)
        }
        return lines
    }

    /// `terminal p1: wait p95 1.2ms · parse 0.3 · build 2.1 · key_to_paint p95 18ms`.
    static func chains(_ metrics: [[String: Any]]) -> [String] {
        struct Row { var hops: [String: [Double]] = [:]; var ends: [String: [Double]] = [:] }
        var rows: [String: Row] = [:]
        for series in metrics {
            guard let labels = series["labels"] as? [String: String], let chain = labels["chain"] else { continue }
            let subject = labels["pane"] ?? labels["window"] ?? labels["plugin"]
            let key = subject.map { "\(chain) \($0)" } ?? chain
            let values = (series["recent"] as? [[Any]] ?? []).compactMap { $0.count > 1 ? ($0[1] as? NSNumber)?.doubleValue : nil }
            if let hop = labels["hop"] {
                rows[key, default: Row()].hops[hop, default: []] += values
            } else if labels["end"] == "1", let name = series["name"] as? String {
                rows[key, default: Row()].ends[String(name.split(separator: ".").last ?? ""), default: []] += values
            }
        }
        return rows.keys.sorted().compactMap { key in
            let row = rows[key]!
            var parts: [String] = []
            for hop in row.hops.keys.sorted() {
                guard let p95 = percentile(row.hops[hop]!, 0.95) else { continue }
                let name = hop.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
                parts.append(parts.isEmpty ? "\(name) p95 \(format(p95))ms" : "\(name) \(format(p95))")
            }
            for end in row.ends.keys.sorted() {
                guard let p95 = percentile(row.ends[end]!, 0.95) else { continue }
                parts.append("\(end) p95 \(format(p95))ms")
            }
            return parts.isEmpty ? nil : "\(key): " + parts.joined(separator: " · ")
        }
    }

    /// The web collector's percentile: the ceil(n * q)-th smallest value.
    static func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int((Double(sorted.count) * q).rounded(.up)) - 1)]
    }

    static func format(_ value: Double) -> String {
        String(format: abs(value) < 10 ? "%.1f" : "%.0f", value)
    }

}

/// Demand-driven process readings for PerformanceBridge. No polling or history here.
final class ProcessSampler {
    struct Sample {
        /// Milliseconds since 1970.
        let t: Double
        let pid: pid_t
        /// WebContent or Tilr.
        let name: String
        /// Percent of one core over the last interval.
        let cpu: Double
        let cpuReady: Bool
        let cpuSeconds: Double
        /// Bytes: the physical footprint (what Activity Monitor calls Memory).
        let rss: Int
    }

    private var last: [pid_t: (cpu: UInt64, wall: UInt64)] = [:]

    /// `ri_user_time` / `ri_system_time` are in mach absolute time units (not ns on Apple silicon).
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func read(_ pid: pid_t, name: String, at now: Double) -> Sample? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        let cpuTime = ticks &* Self.timebase.numer / Self.timebase.denom
        let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var cpu = 0.0
        let cpuReady = last[pid] != nil
        if let previous = last[pid], wall > previous.wall, cpuTime >= previous.cpu {
            cpu = Double(cpuTime - previous.cpu) / Double(wall - previous.wall) * 100
        }
        last[pid] = (cpuTime, wall)
        return Sample(t: now, pid: pid, name: name, cpu: (cpu * 10).rounded() / 10, cpuReady: cpuReady, cpuSeconds: Double(cpuTime) / 1_000_000_000, rss: Int(info.ri_phys_footprint))
    }

    func retainPIDs(_ pids: Set<pid_t>) { last = last.filter { pids.contains($0.key) } }

    /// An exact view/process association, or unavailable. Never substitutes unrelated apps.
    static func webContentPID(_ view: WKWebView) -> pid_t? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard view.responds(to: selector),
              let pid = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

}
