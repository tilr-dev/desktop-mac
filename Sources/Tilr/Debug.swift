import AppKit
import Darwin
import WebKit

/// Debug mode: performance recording for an agent, off by default (`debug:` in the config).
/// On, every tab's page gets the collector (`PerfCollector`, `window.__tilrPerf`) before any of
/// its code runs, and the sampler (`ProcessSampler`) reads the CPU and memory of the pages'
/// WebContent processes and of the app. Tilr Control's `debug` command (Control.swift) turns it
/// on and off and records: it waits, takes the page's dump, adds the samples of that window and
/// writes a JSON file. Off, nothing is injected and nothing ticks.
///
/// `debug.enabled` is the state at launch and after every config change that touches it; the
/// palette's `debug` command and `{"cmd":"debug","action":"on"|"off"}` override it until then.
/// A switch reloads every page: a user script applies to the next navigation.
final class DebugMode {
    var settings: Config.Debug
    private(set) var enabled = false
    /// A `record` is waiting for its window to pass; a second one is refused.
    var recording = false
    let sampler = ProcessSampler()
    /// The tabs to inject into and sample; set by the owner.
    var tabs: () -> [Tab] = { [] }
    /// The state changed (the menu shows it).
    var changed: () -> Void = {}

    init(settings: Config.Debug) {
        self.settings = settings
        enabled = settings.enabled
    }

    /// At launch, once the tabs exist (made with `collector` already in them).
    func launched() {
        if enabled { print("debug: on"); startSampler() }
    }

    /// The collector for a page, or nil while debug is off.
    var collector: String? { enabled ? PerfCollector.script(history: settings.history) : nil }

    /// Turns debug on or off: injects or removes the collector in every tab and reloads its page,
    /// starts or stops the sampler. Same state: nothing happens.
    func set(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        print("debug:", on ? "on" : "off")
        apply()
        changed()
    }

    func toggle() { set(!enabled) }

    /// A new config: `enabled` wins when it changed there; a new history re-injects, a new
    /// sample period restarts the sampler.
    func configChanged(_ new: Config.Debug) {
        let old = settings
        settings = new
        if new.enabled != old.enabled {
            set(new.enabled)
        } else if enabled && new.history != old.history {
            apply()
        } else if enabled && new.sample != old.sample {
            startSampler()
        }
    }

    private func apply() {
        let source = collector
        for tab in tabs() { tab.setCollector(source) }
        if enabled { startSampler() } else { sampler.stop() }
    }

    private func startSampler() {
        sampler.start(period: settings.sample, keep: max(settings.history, 1)) { [weak self] in
            self?.tabs().map(\.webView) ?? []
        }
    }

    /// The palette's row for the `debug` action: the configured title and the state.
    func title(_ base: String) -> String { "\(base): \(enabled ? "on" : "off")" }

    /// `dir:`, `~` expanded, relative to the config folder.
    var dir: String { Config.resolve(settings.dir) }

    /// `record`: the page's dump plus the samples of its window, written as JSON. Returns the
    /// file's path and the summary lines (also in the file).
    func write(dump: [String: Any], seconds: Double, react: Any, path: String?) throws -> (path: String, summary: [String]) {
        let end = Date().timeIntervalSince1970 * 1000
        let samples = sampler.samples(since: end - seconds * 1000)
        var file = dump
        file["process"] = samples.map { ["t": $0.t, "pid": Int($0.pid), "name": $0.name, "cpu": $0.cpu, "rss": $0.rss] as [String: Any] }
        file["config"] = ["react": react, "history": settings.history, "sample": settings.sample] as [String: Any]
        let summary = Self.summary(dump, samples)
        file["summary"] = summary

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

    /// A few lines an agent reads first: frames, lag, the costliest measures, the busiest React
    /// components, the processes' peaks.
    static func summary(_ dump: [String: Any], _ samples: [ProcessSampler.Sample]) -> [String] {
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }
        var lines: [String] = []
        if let frames = dump["frames"] as? [String: Any], number(frames["count"]) == 0,
           dump["visibility"] as? String == "hidden" || number(dump["hiddenMs"]) > 0 {
            lines.append("frames: none (page hidden, rAF paused)")
        } else if let frames = dump["frames"] as? [String: Any] {
            let long = (frames["long"] as? [Any])?.count ?? 0
            lines.append("frames: \(Int(number(frames["count"]))), p50 \(ms(number(frames["p50"]))), p95 \(ms(number(frames["p95"]))), max \(ms(number(frames["max"]))), long (>25 ms) \(long)")
        }
        if let lag = dump["lag"] as? [String: Any] {
            lines.append("lag: p50 \(ms(number(lag["p50"]))), p95 \(ms(number(lag["p95"]))), max \(ms(number(lag["max"])))")
        }
        var measures: [String: (total: Double, count: Int)] = [:]
        for case let measure as [String: Any] in dump["measures"] as? [Any] ?? [] {
            let name = measure["name"] as? String ?? "?"
            let entry = measures[name] ?? (0, 0)
            measures[name] = (entry.total + number(measure["dur"]), entry.count + 1)
        }
        if !measures.isEmpty {
            let top = measures.sorted { $0.value.total > $1.value.total }.prefix(5)
            lines.append("measures: " + top.map { "\($0.key) \(ms($0.value.total)) (\($0.value.count)×)" }.joined(separator: ", "))
        }
        let react = dump["react"] as? String ?? "none"
        if let totals = dump["reactTotals"] as? [String: Any], !totals.isEmpty {
            let top = totals.compactMap { name, value -> (String, Double, Double)? in
                guard let value = value as? [String: Any] else { return nil }
                return (name, number(value["renders"]), number(value["time"]))
            }.sorted { $0.1 > $1.1 }.prefix(5)
            let commits = (dump["reactCommits"] as? [Any])?.count ?? 0
            lines.append("react (\(react)), \(commits) commits: " + top.map { name, renders, time in
                "\(name) ×\(Int(renders))" + (time > 0 ? " \(ms(time))" : "")
            }.joined(separator: ", "))
        } else {
            lines.append("react (\(react)): no renders")
        }
        for name in ["WebContent", "Tilr"] {
            let mine = samples.filter { $0.name == name }
            guard !mine.isEmpty else { continue }
            let cpu = mine.map(\.cpu).max() ?? 0
            let rss = Double(mine.map(\.rss).max() ?? 0) / 1_048_576
            lines.append(String(format: "%@: max cpu %.0f%%, max rss %.0f MB (%d samples)", name, cpu, rss, mine.count))
        }
        return lines
    }
}

/// Samples the CPU and memory of the pages' WebContent processes and the app every `period`
/// seconds while debug is on (`proc_pid_rusage`, deltas of user + system time), keeps `keep`
/// seconds of them (more while a record waits).
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

    private var timer: Timer?
    private var buffer: [Sample] = []
    private var keep: Double = 60
    /// Per pid: the last CPU time (ns) and when it was read (ns).
    private var last: [pid_t: (cpu: UInt64, wall: UInt64)] = [:]
    private var webViews: () -> [WKWebView] = { [] }
    /// A record in progress holds the samples from this moment (ms since 1970).
    var holdSince: Double?

    /// `ri_user_time` / `ri_system_time` are in mach absolute time units (not ns on Apple silicon).
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func start(period: Double, keep: Double, webViews: @escaping () -> [WKWebView]) {
        stop()
        self.keep = keep
        self.webViews = webViews
        timer = Timer.scheduledTimer(withTimeInterval: max(period, 0.05), repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        buffer.removeAll()
        last.removeAll()
    }

    func samples(since: Double) -> [Sample] { buffer.filter { $0.t >= since } }

    private func tick() {
        let now = Date().timeIntervalSince1970 * 1000
        var pids = Self.webContentPIDs(webViews())
        var seen = Set<pid_t>()
        pids = pids.filter { seen.insert($0).inserted }
        for (pid, name) in pids.map({ ($0, "WebContent") }) + [(getpid(), "Tilr")] {
            guard let sample = read(pid, name: name, at: now) else { continue }
            buffer.append(sample)
        }
        let cut = min(now - keep * 1000, holdSince ?? .infinity)
        if let first = buffer.firstIndex(where: { $0.t >= cut }) {
            if first > 0 { buffer.removeFirst(first) }
        } else {
            buffer.removeAll()
        }
        last = last.filter { pid, _ in seen.contains(pid) || pid == getpid() }
    }

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

    /// The pages' WebContent processes: WebKit's private `_webProcessIdentifier`, when the view
    /// answers it; else every `com.apple.WebKit.WebContent` process on the machine.
    static func webContentPIDs(_ webViews: [WKWebView]) -> [pid_t] {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        var pids: [pid_t] = []
        var missing = false
        for webView in webViews {
            guard webView.responds(to: selector),
                  let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
            else { missing = true; continue }
            pids.append(pid)
        }
        if missing || pids.isEmpty { pids += allWebContent() }
        return pids
    }

    private static func allWebContent() -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0) / Int32(MemoryLayout<pid_t>.size)
        guard count > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(count) + 32)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(all.count * MemoryLayout<pid_t>.size))
        let found = Int(bytes) / MemoryLayout<pid_t>.size
        var name = [CChar](repeating: 0, count: 256)
        return all.prefix(found).filter { pid in
            guard pid > 0, proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
            return String(cString: name) == "com.apple.WebKit.WebContent"
        }
    }
}

/// The page's side of debug mode: `globalThis.__tilrPerf`, a user script at document start in
/// the main frame. It keeps the last `history` seconds of frames (requestAnimationFrame deltas;
/// `long` are those over 25 ms: the clock has 1 ms precision, a normal 60 Hz frame reads 17–18;
/// a hidden page gets none, hence `visibility`, `visibilityChanges` and `hiddenMs`),
/// main-thread lag (a zero-delay task queued every 100 ms: how late it ran), performance marks / measures / resources /
/// layout shifts, and React commits through a stub `__REACT_DEVTOOLS_GLOBAL_HOOK__` installed
/// before React loads (a real DevTools hook, when there is one, is wrapped instead).
/// `dump(seconds)` is plain JSON; the web repo's `tilr ctl debug` reads it through `record`.
enum PerfCollector {
    static func userScript(_ source: String) -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static func script(history: Double) -> String {
        """
        (() => {
          if (globalThis.__tilrPerf) return
          const HISTORY = \(max(history, 1)) * 1000
          const LONG = 25
          const PERFORMED_WORK = 1
          const COMPONENT_TAGS = new Set([0, 1, 11, 14, 15])
          const MAX_FIBERS = 20000
          const now = () => performance.now()
          const round = x => Math.round(x * 100) / 100
          const frameT = [], frameD = [], lagT = [], lagD = []
          const marks = [], measures = [], resources = [], shifts = [], commits = []
          // Every visibility change, the first being the state at load; tiny, never pruned.
          const visibility = [{ t: 0, state: document.visibilityState }]
          let navigation = null

          const json = value => {
            if (value === undefined || value === null) return value
            try { return JSON.parse(JSON.stringify(value)) } catch { try { return String(value) } catch { return null } }
          }
          const after = (array, cut) => { let i = 0; while (i < array.length && array[i].t < cut) i++; return i }
          const prune = () => {
            const cut = now() - HISTORY
            let i = 0
            while (i < frameT.length && frameT[i] < cut) i++
            if (i) { frameT.splice(0, i); frameD.splice(0, i) }
            i = 0
            while (i < lagT.length && lagT[i] < cut) i++
            if (i) { lagT.splice(0, i); lagD.splice(0, i) }
            for (const array of [marks, measures, resources, shifts, commits]) {
              const n = after(array, cut)
              if (n) array.splice(0, n)
            }
          }

          // Frames.
          let lastFrame = 0
          const frame = t => {
            if (lastFrame) { frameT.push(t); frameD.push(t - lastFrame) }
            lastFrame = t
            requestAnimationFrame(frame)
          }
          requestAnimationFrame(frame)
          // A hidden page gets no frames; the gap is not a frame.
          document.addEventListener('visibilitychange', () => {
            lastFrame = 0
            visibility.push({ t: now(), state: document.visibilityState })
          })

          // Main-thread lag: every 100 ms a zero-delay task is queued and timed. A MessageChannel
          // message rather than setTimeout(0): WebKit clamps a timer set from a timer to 4+ ms,
          // which would be the floor of every sample.
          let ticks = 0
          let sent = 0
          const channel = new MessageChannel()
          channel.port1.onmessage = () => { const t = now(); lagT.push(t); lagD.push(t - sent) }
          setInterval(() => {
            sent = now()
            channel.port2.postMessage(0)
            if (++ticks % 10 === 0) prune()
          }, 100)

          // Performance entries.
          const supported = (typeof PerformanceObserver !== 'undefined' && PerformanceObserver.supportedEntryTypes) || []
          const take = entry => {
            switch (entry.entryType) {
              case 'mark': marks.push({ t: entry.startTime, name: entry.name, detail: entry.detail ?? undefined }); break
              case 'measure': measures.push({ t: entry.startTime, dur: entry.duration, name: entry.name, detail: entry.detail ?? undefined }); break
              case 'resource': resources.push({ t: entry.startTime, dur: entry.duration, name: entry.name, size: entry.transferSize || entry.encodedBodySize || 0 }); break
              case 'layout-shift': if (!entry.hadRecentInput) shifts.push({ t: entry.startTime, value: entry.value }); break
              case 'navigation': try { navigation = entry.toJSON() } catch {} break
            }
          }
          for (const type of ['mark', 'measure', 'resource', 'layout-shift', 'navigation']) {
            if (!supported.includes(type)) continue
            try { new PerformanceObserver(list => list.getEntries().forEach(take)).observe({ type, buffered: true }) } catch {}
          }
          const observed = type => supported.includes(type)

          // React: a DevTools hook of our own, or the real one wrapped.
          const MEMO = Symbol.for('react.memo'), FORWARD_REF = Symbol.for('react.forward_ref'), LAZY = Symbol.for('react.lazy')
          const typeName = (type, depth = 0) => {
            if (!type || depth > 5) return null
            if (typeof type === 'function') return type.displayName || type.name || null
            if (typeof type !== 'object') return null
            if (type.displayName) return type.displayName
            switch (type.$$typeof) {
              case LAZY: return null
              case MEMO: return typeName(type.type, depth + 1)
              case FORWARD_REF: return typeName(type.render, depth + 1)
              default: return typeName(type.type, depth + 1) || typeName(type.render, depth + 1)
            }
          }
          // An anonymous component goes under its owner's name (dev builds keep _debugOwner), else
          // the nearest named component above it (a prod build's memo(() => …)), marked so it does
          // not merge with that component's own renders.
          const nameOf = fiber => {
            const own = typeName(fiber.elementType) || typeName(fiber.type)
            if (own) return own
            let owner = typeName(fiber._debugOwner?.type)
            for (let up = fiber.return, n = 0; !owner && up && n < 50; up = up.return, n++) {
              if (COMPONENT_TAGS.has(up.tag)) owner = typeName(up.elementType) || typeName(up.type)
            }
            return owner ? owner + '/anonymous' : 'Anonymous'
          }
          const commit = (root, renderer) => {
            const start = now()
            const top = root?.current
            if (!top) return
            const renders = {}
            const times = {}
            let timed = typeof top.actualDuration === 'number'
            let visited = 0
            const stack = [top]
            while (stack.length && visited < MAX_FIBERS) {
              const fiber = stack.pop()
              visited++
              if (COMPONENT_TAGS.has(fiber.tag) && (fiber.flags & PERFORMED_WORK)) {
                const name = nameOf(fiber)
                if (name) {
                  renders[name] = (renders[name] || 0) + 1
                  if (timed && typeof fiber.actualDuration === 'number') {
                    let self = fiber.actualDuration
                    for (let child = fiber.child; child; child = child.sibling) self -= child.actualDuration || 0
                    times[name] = (times[name] || 0) + Math.max(0, self)
                  }
                }
              }
              if (fiber.sibling) stack.push(fiber.sibling)
              // A subtree that bailed out carries no PerformedWork in subtreeFlags: skip it.
              if (fiber.child && (fiber.subtreeFlags === undefined || (fiber.subtreeFlags & PERFORMED_WORK))) stack.push(fiber.child)
            }
            commits.push({ t: start, dur: timed ? round(top.actualDuration) : null, renderer, renders, times })
          }
          const existing = globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__
          if (existing && typeof existing.onCommitFiberRoot === 'function') {
            const original = existing.onCommitFiberRoot
            existing.onCommitFiberRoot = function (id, root, ...rest) {
              try { commit(root, id) } catch {}
              return original.call(this, id, root, ...rest)
            }
          } else if (!existing) {
            let nextId = 1
            const renderers = new Map()
            globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
              supportsFiber: true,
              isDisabled: false,
              renderers,
              rendererInterfaces: new Map(),
              inject(renderer) { const id = nextId++; renderers.set(id, renderer); return id },
              checkDCE() {},
              onScheduleFiberRoot() {},
              onCommitFiberRoot(id, root) { try { commit(root, id) } catch {} },
              onCommitFiberUnmount() {},
              onPostCommitFiberRoot() {},
              setStrictMode() {},
              getFiberRoots() { return new Set() },
              sub() { return () => {} },
              on() {}, off() {}, emit() {},
            }
          }

          const stats = values => {
            if (!values.length) return { p50: 0, p95: 0, max: 0 }
            const sorted = [...values].sort((a, b) => a - b)
            const at = q => sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)]
            return { p50: round(at(0.5)), p95: round(at(0.95)), max: round(sorted[sorted.length - 1]) }
          }

          globalThis.__tilrPerf = {
            version: 1,
            mark(name, detail) {
              const options = detail === undefined ? undefined : { detail }
              performance.mark(name, options)
              if (!observed('mark')) marks.push({ t: now(), name, detail })
            },
            measure(name, start, end, detail) {
              const options = { start }
              if (end !== undefined) options.end = end
              if (detail !== undefined) options.detail = detail
              const entry = performance.measure(name, options)
              if (!observed('measure') && entry) measures.push({ t: entry.startTime, dur: entry.duration, name, detail })
            },
            dump(seconds) {
              prune()
              const end = now()
              const start = Math.max(0, typeof seconds === 'number' && seconds > 0 ? end - seconds * 1000 : end - HISTORY)
              const inside = array => array.slice(after(array, start))
              let i = 0
              while (i < frameT.length && frameT[i] < start) i++
              const deltas = frameD.slice(i)
              const long = []
              for (let k = i; k < frameT.length; k++) if (frameD[k] > LONG) long.push({ t: round(frameT[k] - frameD[k]), dur: round(frameD[k]) })
              let j = 0
              while (j < lagT.length && lagT[j] < start) j++
              const lags = lagD.slice(j)
              const lagSamples = []
              for (let k = j; k < lagT.length; k++) if (lagD[k] > 4) lagSamples.push({ t: round(lagT[k]), lag: round(lagD[k]) })
              const reactCommits = []
              const reactTotals = {}
              for (const c of inside(commits)) {
                reactCommits.push({ t: round(c.t), dur: c.dur, renderer: c.renderer, renders: c.renders })
                for (const name in c.renders) {
                  const total = reactTotals[name] || (reactTotals[name] = { renders: 0, time: 0 })
                  total.renders += c.renders[name]
                  total.time += c.times[name] || 0
                }
              }
              for (const name in reactTotals) reactTotals[name].time = round(reactTotals[name].time)
              if (!navigation) try { navigation = performance.getEntriesByType('navigation')[0]?.toJSON() ?? null } catch {}
              const renderers = []
              try {
                for (const [id, r] of globalThis.__REACT_DEVTOOLS_GLOBAL_HOOK__?.renderers ?? []) {
                  renderers.push({ id, name: String(r?.rendererPackageName ?? 'unknown'), version: String(r?.version ?? 'unknown') })
                }
              } catch {}
              // The state at the window's start, the changes inside it, the hidden time in it.
              let state = visibility[0].state
              const visibilityChanges = []
              for (const v of visibility.slice(1)) {
                if (v.t < start) state = v.state
                else if (v.t <= end) visibilityChanges.push({ t: round(v.t), state: v.state })
              }
              let hiddenMs = 0, from = start
              for (const v of visibilityChanges) {
                if (state === 'hidden') hiddenMs += v.t - from
                state = v.state; from = v.t
              }
              if (state === 'hidden') hiddenMs += end - from
              let react = null
              try { react = globalThis.tilr?.react ?? null } catch {}
              return {
                version: 1,
                start: round(start),
                end: round(end),
                origin: performance.timeOrigin,
                react,
                frames: { count: deltas.length, ...stats(deltas), long },
                lag: { ...stats(lags), samples: lagSamples },
                marks: inside(marks).map(m => ({ t: round(m.t), name: m.name, ...(m.detail === undefined ? {} : { detail: json(m.detail) }) })),
                measures: inside(measures).map(m => ({ t: round(m.t), dur: round(m.dur), name: m.name, ...(m.detail === undefined ? {} : { detail: json(m.detail) }) })),
                resources: inside(resources).map(r => ({ t: round(r.t), dur: round(r.dur), name: r.name, size: r.size })),
                layoutShifts: inside(shifts).map(s => ({ t: round(s.t), value: s.value })),
                navigation: json(navigation) ?? null,
                reactCommits,
                reactTotals,
                renderers,
                visibility: document.visibilityState,
                visibilityChanges,
                hiddenMs: round(hiddenMs),
              }
            },
            clear() {
              for (const array of [frameT, frameD, lagT, lagD, marks, measures, resources, shifts, commits]) array.length = 0
            },
          }
        })()
        """
    }
}
