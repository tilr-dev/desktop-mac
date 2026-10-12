import AppKit
import Darwin
import notify
import WebKit

/// Memory diagnosis for the Performance bridge (`footprint`, `squeeze`, `inspector`) and
/// `tilr ctl debug footprint / squeeze / inspect`. Demand-driven: nothing is cached or polled.
enum Memory {
    /// `debug:` of the config (main.swift keeps it current): the footprint timeout and the squeeze settle.
    static var settings = Config.fallback.debug

    /// A process a tab's page uses: its WebContent processes (scope `page`, `embedded-N`, joined
    /// by `+` when views share one) and the app itself (scope `app`).
    struct Target {
        let pid: pid_t
        /// `webcontent` or `tilr`.
        let role: String
        let scope: String
    }

    /// The page's web view first, then the native providers' views mounted beneath it.
    static func webContent(_ tab: Tab) -> [Target] {
        var views: [WKWebView] = []
        func walk(_ view: NSView) {
            if let web = view as? WKWebView { views.append(web) }
            for child in view.subviews { walk(child) }
        }
        walk(tab.webView)
        var scopes: [pid_t: [String]] = [:]
        for (index, view) in views.enumerated() {
            if let pid = ProcessSampler.webContentPID(view) {
                scopes[pid, default: []].append(index == 0 ? "page" : "embedded-\(index)")
            }
        }
        return scopes.sorted { $0.key < $1.key }.map { Target(pid: $0.key, role: "webcontent", scope: $0.value.joined(separator: "+")) }
    }

    static func targets(_ tab: Tab) -> [Target] {
        webContent(tab) + [Target(pid: getpid(), role: "tilr", scope: "app")]
    }

    // MARK: footprint

    static let footprintTool = "/usr/bin/footprint"

    /// `/usr/bin/footprint -j FILE -p PID …` off the main thread (killed after
    /// `debug.footprint_timeout` seconds); `completion` runs on the main thread with
    /// `{ processes: [{ pid, role, scope, footprint, reclaimable, categories }], took }` or
    /// `{ processes: [], error, took }`. Bytes; `took` in ms.
    static func footprint(_ targets: [Target], completion: @escaping ([String: Any]) -> Void) {
        let timeout = settings.footprintTimeout
        DispatchQueue.global(qos: .userInitiated).async {
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var reply: [String: Any]
            do {
                let data = try run(targets.map(\.pid), timeout: timeout)
                reply = ["processes": try parse(data, targets: targets)]
            } catch {
                reply = ["processes": [] as [Any], "error": (error as? Failure)?.message ?? error.localizedDescription]
            }
            reply["took"] = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1_000_000
            DispatchQueue.main.async { completion(reply) }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The tool's JSON report for `pids`.
    private static func run(_ pids: [pid_t], timeout: Double) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: footprintTool) else { throw Failure(message: "\(footprintTool) is not available") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-footprint-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: footprintTool)
        process.arguments = ["-j", file.path] + pids.flatMap { ["-p", String($0)] }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice  // the text report; the JSON file is what we read
        let errors = Pipe()
        process.standardError = errors
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            throw Failure(message: "\(footprintTool) did not finish in \(timeout) s")
        }
        let stderr = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(footprintTool) exited with \(process.terminationStatus)" + (stderr.isEmpty ? "" : ": \(stderr)"))
        }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            throw Failure(message: "\(footprintTool) wrote no report" + (stderr.isEmpty ? "" : ": \(stderr)"))
        }
        return data
    }

    /// `footprint -j` categories → ours. Each category counts its `dirty` bytes (what makes up the
    /// footprint, compressed included); `reclaimable` sums the Reclaimable column of all categories.
    static let categoryNames = ["WebKit malloc": "malloc",
                                "Owned physical footprint (unmapped) (graphics)": "graphics",
                                "JS VM Gigacage": "js",
                                "JS JIT generated code": "jit"]

    /// One row per target the report covers, in the targets' order: `footprint` is the kernel's
    /// `phys_footprint` (the report's `footprint` when that is missing). A target the tool could
    /// not read (exited, denied) is left out; with none read, the report's errors are thrown.
    static func parse(_ data: Data, targets: [Target]) throws -> [[String: Any]] {
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let processes = report["processes"] as? [[String: Any]] else { throw Failure(message: "unexpected footprint report") }
        let number = { (value: Any?) in (value as? NSNumber)?.int64Value }
        let unit = number(report["bytes per unit"]) ?? 1
        var byPID: [pid_t: [String: Any]] = [:]
        for process in processes {
            guard let pid = number(process["pid"]) else { continue }
            var categories = ["malloc": Int64(0), "graphics": 0, "js": 0, "jit": 0, "other": 0]
            var reclaimable: Int64 = 0
            for (name, value) in process["categories"] as? [String: [String: Any]] ?? [:] {
                categories[categoryNames[name] ?? "other", default: 0] += (number(value["dirty"]) ?? 0) * unit
                reclaimable += (number(value["reclaimable"]) ?? 0) * unit
            }
            let auxiliary = process["auxiliary"] as? [String: Any] ?? [:]
            let footprint = number(auxiliary["phys_footprint"]).map { $0 * unit } ?? (number(process["footprint"]) ?? 0) * unit
            byPID[pid_t(pid)] = ["footprint": footprint, "reclaimable": reclaimable, "categories": categories]
        }
        let rows = targets.compactMap { target -> [String: Any]? in
            guard var row = byPID[target.pid] else { return nil }
            row["pid"] = Int(target.pid)
            row["role"] = target.role
            row["scope"] = target.scope
            return row
        }
        if rows.isEmpty, !targets.isEmpty {
            let errors = (report["errors"] as? [Any] ?? []).map { "\($0)" }
            throw Failure(message: errors.isEmpty ? "footprint read none of the processes" : errors.joined(separator: "; "))
        }
        return rows
    }

    // MARK: squeeze

    /// The Darwin notification WebKit's processes treat as memory pressure (WebKit's
    /// MemoryPressureHandler): caches and freeable memory are released. System-wide: every
    /// WebKit process on the machine (Safari, Mail, other apps) receives it. WebKit has no
    /// per-view or per-process memory-pressure call (checked on macOS 26: none on WKWebView,
    /// WKProcessPool, WKWebsiteDataStore), so this is the only lever short of a reload.
    static let lowMemory = "org.WebKit.lowMemory"

    /// Posts `org.WebKit.lowMemory`, waits `debug.squeeze_settle` seconds, and replies on the main
    /// thread with `{ method: 'notify', notification, systemWide: true, note, before, after,
    /// processes: [{ pid, scope, before, after }] }`: the tab's WebContent phys_footprint in bytes
    /// (proc_pid_rusage), summed and per process; `{ error }` when the post fails.
    static func squeeze(_ tab: Tab, completion: @escaping ([String: Any]) -> Void) {
        let targets = webContent(tab)
        let before = targets.map { physFootprint($0.pid) }
        let status = notify_post(lowMemory)
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            completion(["method": "notify", "notification": lowMemory, "error": "notify_post failed with status \(status)"])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.squeezeSettle) {
            let after = targets.map { physFootprint($0.pid) }
            let sum = { (values: [Int64?]) -> Any in
                let known = values.compactMap { $0 }
                return known.isEmpty ? NSNull() : known.reduce(0, +)
            }
            completion([
                "method": "notify",
                "notification": lowMemory,
                "systemWide": true,
                "note": "Darwin notification \(lowMemory): every WebKit process on this Mac releases memory, not only Tilr's",
                "settle": settings.squeezeSettle * 1000,
                "before": sum(before),
                "after": sum(after),
                "processes": targets.indices.map { index -> [String: Any] in
                    ["pid": Int(targets[index].pid), "scope": targets[index].scope,
                     "before": before[index] as Any? ?? NSNull(), "after": after[index] as Any? ?? NSNull()]
                },
            ])
        }
    }

    /// The kernel's phys_footprint (Activity Monitor's Memory) in bytes, nil when unreadable.
    static func physFootprint(_ pid: pid_t) -> Int64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    // MARK: inspector

    /// Opens Web Inspector for the tab's page through WebKit's private `-[WKWebView _inspector]`
    /// and `-[_WKInspector show]`, both resolved at runtime. The in-app inspector needs the
    /// page's developer extras (private `-[WKPreferences _setDeveloperExtrasEnabled:]`, through
    /// KVC), turned on here on request only. `{ shown: true }` or `{ shown: false, reason }`.
    static func inspector(_ tab: Tab) -> [String: Any] {
        let webView = tab.webView
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else {
            return ["shown": false, "reason": "WKPreferences has no _setDeveloperExtrasEnabled: on this macOS; use Safari → Develop → Tilr"]
        }
        preferences.setValue(true, forKey: "developerExtrasEnabled")
        guard webView.responds(to: NSSelectorFromString("_inspector")) else {
            return ["shown": false, "reason": "WKWebView has no _inspector on this macOS; use Safari → Develop → Tilr"]
        }
        guard let inspector = webView.value(forKey: "_inspector") as? NSObject else {
            return ["shown": false, "reason": "the web view has no inspector"]
        }
        let show = NSSelectorFromString("show")
        guard inspector.responds(to: show) else {
            return ["shown": false, "reason": "_WKInspector has no show on this macOS; use Safari → Develop → Tilr"]
        }
        inspector.perform(show)
        return ["shown": true]
    }
}
