#!/usr/bin/env python3
"""Verify the native CLI adapter exports the web recording without a second data format."""
import os
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'Sources/Tilr/Debug.swift').read_text()
source = source[:source.index('/// Demand-driven process readings')]

# Control's record: refuses a running page recording, writes finish()'s recording, and cuts a
# snapshot() only for an older plugin whose finish() returns undefined.
control = (Path(__file__).resolve().parents[1] / 'Sources/Tilr/Control.swift').read_text()
for needle in ["if (p.recording === true) throw new Error('A recording is already running (Performance window)')",
               "const r = p.finish(); if (r === null) throw new Error('Collection stopped during the recording'); if (r !== undefined) return { recording: r };",
               "dump = DebugMode.cut(snapshot, from: t)",
               "mechanism: 'none'"]:
    assert needle in control, needle
assert 'p.finish(); const d = p.snapshot()' not in control
fixture = r'''
struct Config {
    struct Debug { var enabled = false; var dir: String }
    static func resolve(_ value: String) -> String { value }
}
let directory = CommandLine.arguments[1]
let adapter = DebugMode(settings: Config.Debug(dir: directory))
precondition(adapter.collector == nil)
let recording: [String: Any] = ["version": 1, "origin": 1000, "started": 0, "ended": 2000,
    "react": "profiling", "dropped": 0,
    "events": [["kind": "react", "t": 1], ["kind": "component", "count": 14, "t": 1]],
    "samples": [["t": 1000, "processes": [["pid": 12, "memory": 1000]]]]]
let result = try adapter.write(dump: recording, path: directory + "/record.json")
let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: result.path))) as! NSDictionary
precondition(restored.isEqual(to: recording), "Native export must preserve the web schema")
precondition(result.summary[0].contains("1 React commits, 14 component renders"))

// An older plugin's snapshot reaching back before the recording: cut() keeps only the recording's window.
let json = """
{"version": 1, "origin": 1000, "started": 0, "ended": 4000, "react": "prod", "dropped": {},
 "events": [{"kind": "react", "t": 1500}, {"kind": "react", "t": 2600}],
 "samples": [{"t": 2000, "fps": null}, {"t": 3000, "fps": 60}, {"t": 4000, "fps": 58}],
 "metrics": [
  {"name": "server.wait", "labels": {"chain": "terminal", "hop": "10-wait", "pane": "p1"}, "count": 9, "sum": 90, "min": 1, "max": 50, "last": 1.2, "t": 3900,
   "recent": [[1900, 50], [2500, 1.0], [3000, 1.2], [3900, 1.1]], "seconds": [[1, 1, 50], [2, 1, 1.0], [3, 2, 2.3]]},
  {"name": "server.parse", "labels": {"chain": "terminal", "hop": "20-parse", "pane": "p1"}, "count": 3, "sum": 0.9, "min": 0.3, "max": 0.3, "last": 0.3, "t": 3900,
   "recent": [[2600, 0.3], [3900, 0.3]], "seconds": [[2, 1, 0.3], [3, 1, 0.3]]},
  {"name": "terminal.build", "labels": {"chain": "terminal", "hop": "30-build", "pane": "p1"}, "count": 2, "sum": 4.2, "min": 2.1, "max": 2.1, "last": 2.1, "t": 3900,
   "recent": [[2700, 2.1], [3900, 2.1]], "seconds": [[2, 1, 2.1], [3, 1, 2.1]]},
  {"name": "terminal.echo", "labels": {"chain": "terminal", "end": "1", "pane": "p1"}, "count": 2, "sum": 35, "min": 17, "max": 18, "last": 18, "t": 3900,
   "recent": [[2800, 17], [3900, 18]], "seconds": [[2, 1, 17], [3, 1, 18]]},
  {"name": "server.wait", "labels": {"chain": "terminal", "hop": "10-wait", "pane": "p2"}, "count": 1, "sum": 5, "min": 5, "max": 5, "last": 5, "t": 1000,
   "recent": [[1000, 5]], "seconds": [[1, 1, 5]]},
  {"name": "x.y", "labels": {}, "count": 1, "sum": 1, "min": 1, "max": 1, "last": 1, "t": 2200, "recent": [[2200, 1]], "seconds": [[2, 1, 1]]}
 ]}
"""
let snapshot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
let cut = DebugMode.cut(snapshot, from: 2400)
precondition((cut["started"] as! NSNumber).doubleValue == 2400)
precondition((cut["events"] as! [[String: Any]]).count == 1)
precondition((cut["samples"] as! [[String: Any]]).count == 2)
let series = cut["metrics"] as! [[String: Any]]
precondition(series.count == 6, "series are kept even without observations in the window")
let wait = series[0]
precondition((wait["recent"] as! [[NSNumber]]).map { $0[0].doubleValue } == [2500, 3000, 3900])
precondition((wait["seconds"] as! [[NSNumber]]).map { $0[0].intValue } == [2, 3], "second >= floor(2400 / 1000)")
precondition((wait["count"] as! NSNumber).intValue == 9 && (wait["max"] as! NSNumber).doubleValue == 50, "totals stay session totals")
precondition((series[4]["recent"] as! [Any]).isEmpty && (series[4]["seconds"] as! [Any]).isEmpty)
let lines = DebugMode.summary(cut)
precondition(lines.contains("Samples: 2, FPS measured in 2, p50 58"), lines.joined(separator: "\n"))
precondition(lines.contains { $0.hasPrefix("Metrics: 6 series;") && $0.contains("≤256") && $0.contains("session totals") })
let chains = DebugMode.chains(series)
precondition(chains == ["terminal p1: wait p95 1.2ms · parse 0.3 · build 2.1 · echo p95 18ms"], chains.joined(separator: "\n"))
precondition(lines.suffix(1) == chains[...])
precondition(DebugMode.percentile([1, 2, 3, 4], 0.95) == 4 && DebugMode.percentile([], 0.95) == nil)
print("Native Performance adapter passed: shared recording round-trip, legacy window cut, chain summary")
'''
with tempfile.TemporaryDirectory(prefix='tilr-performance-adapter-') as directory:
    path = Path(directory) / 'adapter.swift'
    path.write_text(source + fixture)
    subprocess.run(['/usr/bin/swift', str(path), directory], check=True,
                   env={**os.environ, 'CLANG_MODULE_CACHE_PATH': directory + '/cache'})
