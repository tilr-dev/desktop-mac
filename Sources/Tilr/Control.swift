import AppKit
import ImageIO
import Gitpm
import Network
import UniformTypeIdentifiers
import WebKit

/// Tilr Control: how an agent (or `tilr ctl`, or `tilr mcp`) drives the running app. A server on
/// a unix socket (`control.socket` in the config), one JSON object per line each way:
///
///   { "cmd": "apps" }                               the app catalog and the key window’s application
///   { "cmd": "switch", "app": "Notes" }             focus an app window or open one; legacy slide is ignored
///   { "cmd": "reload" }                             reload the page
///   { "cmd": "snapshot", "path": "~/x.png" }        a picture of the page, as the window shows it
///   { "cmd": "console", "clear": false }            the page's console.* and errors, oldest first
///   { "cmd": "eval", "js": "return 1 + 1" }         the body of an async function in the page
///   { "cmd": "call", "service": "plugins", "method": "toggle", "args": ["counter"] }
///   { "cmd": "debug", "action": "status" }         Performance service: enabled, react (the page's
///                                                   build), mechanism, active (a page recording), dir,
///                                                   recording (a CLI record); mechanism 'none' + reason
///                                                   while the page loads or without the plugin;
///                                                   highRefreshRate: true, false or 'unavailable'
///                                                   (web.high_refresh_rate as applied to the page)
///   { "cmd": "debug", "action": "on" }              shared Performance switch in the selected tab; reload scheduled
///   { "cmd": "debug", "action": "record", "seconds": 5, "path": "~/x.json" }
///                                                   performance.record(), waits, writes finish()'s recording
///                                                   (refused while the Performance window records) to path (default
///                                                   debug.dir/<date>.json); { path, summary: [lines] }
///   { "cmd": "debug", "action": "footprint" }       { processes: [{ pid, role, scope, footprint, reclaimable,
///                                                   categories: { malloc, graphics, js, jit, other } }], took } (bytes, ms)
///   { "cmd": "debug", "action": "squeeze" }         posts org.WebKit.lowMemory (every WebKit process on the Mac);
///                                                   { method: 'notify', before, after, processes, … } (bytes)
///   { "cmd": "debug", "action": "inspect" }         opens Web Inspector for the tab: { shown } or { shown: false, reason }
///   { "cmd": "plugin-manager" }                     read-only: { workspace, catalog, open, git: "ok" or why not,
///                                                   plugins: [{ id, source, version, commit, enabled, previous?, forkOf? }] }
///                                                   (state.json, the workspace is not opened; error: { kind, message })
///   { "cmd": "gitpm", "command": "list", "args": {} }  embedded gitpm; { result: JSON }, or
///                                                   error: { code, kind, message, id?, lostWork, plugins }
///                                                   See docs/gitpm-control.md for all commands and arguments.
///
/// `call` runs a method of a service of the page's cordis root (`window.tilr.root.get(service)`):
/// `plugins.list / toggle / reload`, `layout.list / open / close / float / tile`,
/// `windows.list`, and whatever other plugins provide. That is the whole control surface: a
/// plugin that provides a service is driven the same way, with nothing added here.
///
/// Native windows: `{ "cmd": "shell", "op": "list" }` returns `windows` with host, app,
/// frame {x,y,width,height}, screen ID (or null), key and space (Space IDs).
/// `open` takes app and optional frame and always creates a new host; `close` and `focus`
/// require host; `move` requires host and frame. Frames are AppKit screen points (bottom-left
/// origin), with finite coordinates and positive sizes. Move leaves desktop fullscreen for
/// window mode; native fullscreen must be exited first. Focus does not activate Tilr.
/// Every command takes `"host"` (stable native UUID), `"app"` and `"id"` (echoed).
/// Host selects an exact page; unknown hosts and mismatching apps fail. Without host, app
/// selects its most recently key window (or opens one); omitted app uses the key host.
/// Instance-wide commands validate host without changing scope. `apps` includes host IDs.
/// The reply is `{ "id", "ok": true, …result }` or `{ "id", "ok": false, "error": "…" }`. Values
/// cross as JSON: a result the page cannot stringify comes back as a string.
final class ControlServer {
    let path: String
    private let shells: () -> [Shell]
    private let openWindow: (Site.App, NSRect?) -> Shell
    private let tabs: () -> [Tab]
    private let current: () -> Tab?
    private let apps: () -> [Site.App]
    private let resolve: (String) -> Tab?
    /// Focus a native host; legacy slide selection remains accepted without animation.
    private let select: (Tab, Bool) -> Bool
    /// `control.load_timeout`: seconds a command waits for an app's first page load.
    private let loadTimeout: () -> Double
    private let debug: DebugMode
    /// `plugin-manager`: the plugin manager's state (PluginManagerHost.swift).
    private let gitpm: (String, [String: Any]) async throws -> Any
    private let pluginManager: () async throws -> [String: Any]
    private var listener: NWListener?

    init(path: String, shells: @escaping () -> [Shell], openWindow: @escaping (Site.App, NSRect?) -> Shell, tabs: @escaping () -> [Tab], current: @escaping () -> Tab?, select: @escaping (Tab, Bool) -> Bool,
         apps: @escaping () -> [Site.App], resolve: @escaping (String) -> Tab?,
         loadTimeout: @escaping () -> Double, debug: DebugMode, gitpm: @escaping (String, [String: Any]) async throws -> Any, pluginManager: @escaping () async throws -> [String: Any]) {
        self.shells = shells
        self.openWindow = openWindow
        self.path = path
        self.tabs = tabs
        self.current = current
        self.apps = apps
        self.resolve = resolve
        self.select = select
        self.loadTimeout = loadTimeout
        self.debug = debug
        self.gitpm = gitpm
        self.pluginManager = pluginManager
    }

    func start() {
        // Another Tilr may be on the socket: then it keeps it, and this one runs without control.
        // A socket file nobody answers on was left by a crashed run and would refuse the bind.
        if Self.answers(path) {
            print("control: another Tilr is on \(path); control is off in this one")
            return
        }
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            print("control: \(path): \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener?.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                print("control: failed:", error)
                self.listener?.cancel()
                self.listener = nil
            case .ready: print("control:", self.path)
            default: break
            }
        }
        listener?.start(queue: .main)
    }

    func stop() {
        guard listener != nil else { return }
        listener?.cancel()
        unlink(path)
    }

    /// Whether a server accepts connections on the unix socket at `path`.
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        return result == 0
    }

    /// One client: lines in, lines out, until it hangs up.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
                    self.handle(line) { reply in
                        connection.send(content: reply + Data([0x0A]), completion: .contentProcessed { _ in })
                    }
                }
                if done || error != nil { connection.cancel(); return }
                receive()
            }
        }
        receive()
    }

    private func handle(_ line: Data, reply: @escaping (Data) -> Void) {
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let id = request?["id"] ?? NSNull()
        func send(_ body: [String: Any], ok: Bool) {
            var object = body
            object["id"] = id
            object["ok"] = ok
            let data = (try? JSONSerialization.data(withJSONObject: object))
                ?? Data("{\"ok\":false,\"error\":\"the reply is not JSON\"}".utf8)
            reply(data)
        }
        guard let request else { return send(["error": "not a JSON object: \(String(decoding: line, as: UTF8.self))"], ok: false) }
        guard let cmd = request["cmd"] as? String else { return send(["error": "no cmd"], ok: false) }
        Task { @MainActor in
            do {
                send(try await self.run(cmd, request), ok: true)
            } catch let failure as PluginManagerFailure {
                send(["error": failure.controlJSON], ok: false)
            } catch {
                send(["error": Self.describe(error)], ok: false)
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A JavaScript exception by its message, anything else by its description.
    static func describe(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        if let message = info["WKJavaScriptExceptionMessage"] as? String { return message }
        return error.localizedDescription
    }

    @MainActor
    func run(_ cmd: String, _ request: [String: Any]) async throws -> [String: Any] {
        // Validate explicit addressing even for instance-wide commands.
        let selected: Shell?
        if let value = request["host"] {
            guard let id = value as? String, let host = shells().first(where: { $0.hostID.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw Failure(message: "unknown host: \(value)")
            }
            if let app = request["app"] as? String, host.current?.app.name != app {
                throw Failure(message: "host \(host.hostID) does not show app \(app)")
            }
            selected = host
        } else { selected = nil }
        func tab() throws -> Tab {
            if let selected, let tab = selected.current { return tab }
            if let name = request["app"] as? String {
                guard let tab = resolve(name) else {
                    throw Failure(message: "no app \"\(name)\"; the apps: \(apps().map(\.name).joined(separator: ", "))")
                }
                return tab
            }
            guard let tab = current() else { throw Failure(message: "no app") }
            return tab
        }
        /// The selected host page loads if needed, and the command
        /// waits up to control.load_timeout for a load under way (a page that failed to load
        /// does not wait).
        func page() async throws -> Tab {
            let tab = try tab()
            tab.loadIfNeeded()
            if !tab.isLoaded { await tab.firstLoad(within: loadTimeout()) }
            return tab
        }
        switch cmd {
        case "shell":
            return try shellCommand(request, selected: selected)
        case "apps":
            return ["apps": apps().map { app -> [String: Any] in
                let tab = current().flatMap { $0.app.name == app.name ? $0 : nil } ?? tabs().first { $0.app.name == app.name }
                return ["name": app.name, "site": app.root.path, "url": tab?.webView.url?.absoluteString ?? "",
                        "current": current()?.app.name == app.name, "loaded": tab?.started ?? false,
                        "hosts": shells().filter { $0.current?.app.name == app.name }.map { $0.hostID.uuidString }]
            }]
        case "switch":
            let tab = try tab()
            // Legacy clients may still send slide; native host selection is immediate.
            let slid = select(tab, request["slide"] as? Bool ?? false)
            return slid ? ["app": tab.app.name, "slide": true] : ["app": tab.app.name]
        case "reload":
            let tab = try tab()
            tab.reload()
            return ["app": tab.app.name]
        case "snapshot":
            guard let path = request["path"] as? String else { throw Failure(message: "snapshot: no path") }
            let tab = try await page()
            let image = try await tab.webView.takeSnapshot(configuration: nil)
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try await PNG.write(image, to: file)
            return ["path": file.path, "width": Int(image.size.width), "height": Int(image.size.height)]
        case "console":
            let tab = try tab()
            let messages = tab.console.entries.map { ["time": $0.time, "type": $0.type, "text": $0.text] as [String: Any] }
            if request["clear"] as? Bool == true { tab.console.removeAll() }
            return ["messages": messages]
        case "eval":
            guard let js = request["js"] as? String else { throw Failure(message: "eval: no js") }
            // An expression is returned; a body with a `return` of its own runs as written.
            let body = js.range(of: #"\breturn\b"#, options: .regularExpression) == nil ? "return (\(js))" : js
            return ["value": try await evaluate(try await page(), body: body, arguments: [:])]
        case "call":
            guard let service = request["service"] as? String, let method = request["method"] as? String else {
                throw Failure(message: "call: service and method are required")
            }
            let args = request["args"] as? [Any] ?? []
            let body = """
                const target = window.tilr?.root.get(service)
                if (!target) throw new Error(`no service "${service}" is running`)
                const member = target[method]
                if (typeof member !== 'function') {
                  if (member !== undefined) return member
                  throw new Error(`${service}.${method} is not a method`)
                }
                return await member.apply(target, args)
                """
            return ["value": try await evaluate(try await page(), body: body, arguments: ["service": service, "method": method, "args": args])]
        case "debug":
            // status reports an app that has not loaded; the rest need its page.
            let action = request["action"] as? String ?? "status"
            return try await debugCommand(action == "status" ? try tab() : try await page(), request)
        case "native-plugins":
            return ["plugins": try tab().nativePlugins.status()]
        case "native-call":
            guard let service = request["service"] as? String else { throw Failure(message: "native-call: service required") }
            return try await page().nativePlugins.request(service: service, body: request["request"] as? [String: Any] ?? [:])
        case "browser":
            return try await page().nativePlugins.request(service: "browser", body: request)
        case "gitpm":
            guard Set(request.keys).isSubset(of: ["cmd", "id", "host", "app", "command", "args"]) else {
                throw PluginManagerFailure(kind: "invalid_argument", message: "gitpm: unexpected request fields")
            }
            guard let command = request["command"] as? String else {
                throw PluginManagerFailure(kind: "invalid_argument", message: "gitpm: command is required")
            }
            let arguments: [String: Any]
            if let value = request["args"] {
                guard let object = value as? [String: Any] else {
                    throw PluginManagerFailure(kind: "invalid_argument", message: "gitpm: args must be an object")
                }
                arguments = object
            } else { arguments = [:] }
            return ["result": try await gitpm(command, arguments)]
        case "plugin-manager":
            return try await pluginManager()
        default:
            throw Failure(message: "unknown cmd \"\(cmd)\"; one of shell, apps, switch, reload, snapshot, console, eval, call, debug, browser, plugin-manager, gitpm")
        }
    }

    @MainActor
    private func shellCommand(_ request: [String: Any], selected: Shell?) throws -> [String: Any] {
        func describe(_ host: Shell) -> [String: Any] {
            let frame = host.window.frame
            return ["host": host.hostID.uuidString, "app": host.current?.app.name ?? "",
                    "frame": ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height],
                    "screen": host.window.screen.flatMap(WindowRecord.screenID).map { $0 as Any } ?? NSNull(),
                    "key": host.window.isKeyWindow, "space": Spaces.of(host.window)]
        }
        func frame() throws -> NSRect {
            guard let values = request["frame"] as? [String: Any] else { throw Failure(message: "shell: frame is required") }
            func number(_ key: String) throws -> Double {
                guard let n = values[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                    throw Failure(message: "shell: frame.\(key) must be a finite number")
                }
                return n.doubleValue
            }
            let rect = try NSRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            guard rect.size.width > 0, rect.size.height > 0 else { throw Failure(message: "shell: frame size must be positive") }
            return rect
        }
        func move(_ host: Shell, _ frame: NSRect) throws {
            guard !host.window.styleMask.contains(.fullScreen) else { throw Failure(message: "shell: leave native fullscreen before moving the window") }
            if host.mode == .fullscreen { host.set(.window) }
            host.window.setFrame(frame, display: true)
            host.stateChanged?()
        }
        switch request["op"] as? String {
        case "list": return ["windows": shells().map(describe)]
        case "open":
            guard selected == nil else { throw Failure(message: "shell open: host is not accepted") }
            guard let name = request["app"] as? String, let app = apps().first(where: { $0.name == name }) else {
                throw Failure(message: "shell open: a configured app is required")
            }
            let geometry = try request["frame"].map { _ in try frame() }
            let host = openWindow(app, geometry)
            return describe(host)
        case "close", "focus", "move":
            guard let host = selected else { throw Failure(message: "shell: host is required") }
            switch request["op"] as? String {
            case "close": host.window.close(); return ["host": host.hostID.uuidString]
            case "focus": if let tab = host.current { _ = select(tab, false) }
            default: try move(host, frame())
            }
            return describe(host)
        default: throw Failure(message: "shell: op must be list, open, close, focus or move")
        }
    }

    /// `debug`: status, on, off, record (Debug.swift); footprint, squeeze, inspect (Memory.swift).
    @MainActor
    private func debugCommand(_ tab: Tab, _ request: [String: Any]) async throws -> [String: Any] {
        let service = "const p = globalThis.tilr?.services?.performance; if (!p) throw new Error('Install and enable the Performance web plugin first.');"
        let action = request["action"] as? String ?? "status"
        switch action {
        case "status":
            // Answers even while the page loads or without the plugin: { enabled: false, mechanism: 'none', reason }.
            var result: [String: Any]
            if !tab.started {
                result = ["enabled": false, "mechanism": "none", "reason": "The app is not loaded yet (switch.preload)"]
            } else if !tab.isLoaded {
                result = ["enabled": false, "mechanism": "none", "reason": "The page is still loading"]
            } else {
                do {
                    let value = try await evaluate(tab, body: "const p = globalThis.tilr?.services?.performance; if (!p) return { enabled: false, mechanism: 'none', reason: globalThis.tilr ? 'The Performance web plugin is not installed or not enabled' : 'The page is still loading' }; return { enabled: p.enabled, react: tilr.react, mechanism: 'performance', active: p.recording === true };", arguments: [:])
                    result = value as? [String: Any] ?? ["enabled": false, "mechanism": "none", "reason": "Unexpected reply from the page"]
                } catch {
                    result = ["enabled": false, "mechanism": "none", "reason": Self.describe(error)]
                }
            }
            result["dir"] = debug.dir
            result["recording"] = debug.recording
            result["highRefreshRate"] = tab.highRefreshRate
            return result
        case "on", "off":
            return try await evaluate(tab, body: service + "if (p.enabled !== on) setTimeout(() => { void p.enable(on) }, 0); return { mechanism: 'performance', requested: on, reloading: p.enabled !== on };", arguments: ["on": action == "on"]) as? [String: Any] ?? [:]
        case "record":
            guard !debug.recording else { throw Failure(message: "performance: a CLI record is in progress") }
            let seconds = (request["seconds"] as? NSNumber)?.doubleValue ?? 5
            guard seconds.isFinite && seconds > 0 && seconds <= 60 else { throw Failure(message: "performance: seconds must be in (0, 60]") }
            // The service's own recording: record() puts the collector's frame loop on demand
            // ('recording') until finish(), so the samples carry FPS.
            let start: Any
            do { start = try await evaluate(tab, body: service + "if (!p.enabled) throw new Error('Performance collection is off'); if (p.recording === true) throw new Error('A recording is already running (Performance window)'); const t = performance.now(); p.record(); return { t, origin: performance.timeOrigin };", arguments: [:]) } catch {
                // Never hijack a recording started in the Performance window.
                let message = Self.describe(error)
                if message.contains("A recording is already running") { throw Failure(message: "performance: a recording is already running in the Performance window; stop it there first") }
                throw Failure(message: "performance: " + message.replacingOccurrences(of: "Error: ", with: ""))
            }
            guard let start = start as? [String: Any], let t = (start["t"] as? NSNumber)?.doubleValue else { throw Failure(message: "performance: missing start") }
            debug.recording = true
            defer { debug.recording = false }
            // finish() returns the recording cut to its window (incl. dropped), null when none was in
            // progress; an older plugin's finish() returns undefined: snapshot() + DebugMode.cut.
            let finish = service + "if (performance.timeOrigin !== origin) throw new Error('The page reloaded during the recording'); const r = p.finish(); if (r === null) throw new Error('Collection stopped during the recording'); if (r !== undefined) return { recording: r }; const d = p.snapshot(); if (!d) throw new Error('Collection stopped during the recording'); return { snapshot: d };"
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch {
                _ = try? await evaluate(tab, body: finish, arguments: start)
                throw error
            }
            let value = try await evaluate(tab, body: finish, arguments: start)
            let reply = value as? [String: Any]
            let dump: [String: Any]
            if let recording = reply?["recording"] as? [String: Any] { dump = recording }
            else if let snapshot = reply?["snapshot"] as? [String: Any] { dump = DebugMode.cut(snapshot, from: t) }
            else { throw Failure(message: "performance: invalid recording") }
            let written = try debug.write(dump: dump, path: request["path"] as? String)
            return ["path": written.path, "summary": written.summary]
        case "footprint":
            // Memory.swift: /usr/bin/footprint categories of the tab's WebContent processes and Tilr.
            return await withCheckedContinuation { done in Memory.footprint(Memory.targets(tab)) { done.resume(returning: $0) } }
        case "squeeze":
            // org.WebKit.lowMemory (system-wide), then the WebContent footprint ~debug.squeeze_settle s later.
            return await withCheckedContinuation { done in Memory.squeeze(tab) { done.resume(returning: $0) } }
        case "inspect":
            return Memory.inspector(tab)
        default:
            throw Failure(message: "performance: expected status, on, off, record, footprint, squeeze or inspect")
        }
    }

    /// Runs `body` as an async function in the page and brings its value over as JSON.
    @MainActor
    private func evaluate(_ tab: Tab, body: String, arguments: [String: Any]) async throws -> Any {
        let source = """
            const __value = await (async () => {
            \(body)
            })()
            try { return JSON.stringify(__value === undefined ? null : __value) ?? 'null' } catch { return JSON.stringify(String(__value)) }
            """
        let result = try await tab.webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
        guard let text = result as? String, let data = text.data(using: .utf8) else { return NSNull() }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? text
    }
}

/// Catches the page's console.* calls and errors for `console` (Tab installs it when control is
/// on and `control.console_capture`). A separate object: the content controller retains its
/// handlers, the tab must not retain itself.
final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    static let name = "tilrConsole"
    weak var tab: Tab?

    /// Wraps console.* and reports window errors, at document start, in every frame. Entries
    /// are queued and posted as one array per microtask checkpoint; each keeps at most
    /// `entryMax` characters (`control.console_entry_max`), a cut one ends in "…".
    /// An object argument is JSON as `JSON.stringify` makes it (`String(a)` when that fails),
    /// but serializing stops once the entry is over `entryMax`: a replacer rebuilds the text
    /// as it goes and ends the walk there, so a huge object costs about its first `entryMax`
    /// characters (plus enumerating the keys of the objects it opens). The kept text is the
    /// same as a full `JSON.stringify` cut; only a cycle or BigInt past the cut no longer turns
    /// the argument into `String(a)`.
    static func script(entryMax: Int) -> String {
        """
        (() => {
          const max = \(max(entryMax, 0))
          let queue = []
          const flush = () => {
            const entries = queue
            queue = []
            try { window.webkit.messageHandlers.\(name).postMessage(entries) } catch {}
          }
          const stringify = JSON.stringify, isArray = Array.isArray
          const over = {}
          // JSON.stringify(a), or, once that is longer than budget characters, its first budget
          // characters and a bit more: the replacer rebuilds the text as JSON.stringify walks
          // (preorder, values after toJSON) and stops it there.
          const encode = (a, budget) => {
            if (typeof a === 'string') return a
            if (a instanceof Error) return a.stack || a.message
            let out = ''
            // The open objects and arrays: [holder, is an array, members written].
            const open = []
            try {
              return stringify(a, function (k, v) {
                const omitted = v === undefined || typeof v === 'function' || typeof v === 'symbol'
                if (open.length) {
                  while (open[open.length - 1][0] !== this) out += open.pop()[1] ? ']' : '}'
                  const top = open[open.length - 1]
                  if (omitted && !top[1]) return v
                  if (top[2]++) out += ','
                  if (!top[1]) out += stringify(k) + ':'
                } else if (omitted) return v
                let w = v
                if (w instanceof Number) w = Number(w)
                else if (w instanceof String) w = String(w)
                else if (w instanceof Boolean) w = w.valueOf()
                if (omitted || w === null) out += 'null'
                else if (typeof w === 'boolean') out += w ? 'true' : 'false'
                else if (typeof w === 'number') out += isFinite(w) ? String(w) : 'null'
                else if (typeof w === 'string') out += stringify(w.slice(0, Math.max(budget - out.length + 2, 0)))
                else if (typeof w === 'object') { const list = isArray(w); out += list ? '[' : '{'; open.push([w, list, 0]) }
                if (out.length > budget) throw over
                return v
              }) ?? String(a)
            } catch (e) {
              return e === over ? out : String(a)
            }
          }
          const post = (type, args) => {
            let text = ''
            for (let i = 0; i < args.length && text.length <= max; i++) {
              if (i) text += ' '
              text += encode(args[i], max - text.length)
            }
            if (text.length > max) text = text.slice(0, max) + '…'
            if (queue.push({ type, text, time: Date.now() }) === 1) queueMicrotask(flush)
          }
          for (const type of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[type]
            console[type] = (...args) => { post(type, args); original.apply(console, args) }
          }
          window.addEventListener('error', e => post('pageerror', [e.message]))
          window.addEventListener('unhandledrejection', e => post('pageerror', [e.reason instanceof Error ? e.reason.stack || e.reason.message : String(e.reason)]))
        })()
        """
    }

    /// An array of `{ type, text, time }` (time in ms since 1970), oldest first.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let entries = message.body as? [[String: Any]] else { return }
        for body in entries {
            let time = (body["time"] as? NSNumber).map { $0.doubleValue / 1000 } ?? Date().timeIntervalSince1970
            tab.log(type: body["type"] as? String ?? "log", text: body["text"] as? String ?? "", time: time)
        }
    }
}

/// The last `capacity` console entries, in a fixed ring: appending never moves the others.
struct ConsoleLog {
    private var ring: [Tab.ConsoleEntry] = []
    /// Where the next entry goes once the ring is full; then also the oldest entry.
    private var next = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 0)
        ring.reserveCapacity(self.capacity)
    }

    mutating func append(_ entry: Tab.ConsoleEntry) {
        guard capacity > 0 else { return }
        if ring.count < capacity { ring.append(entry); return }
        ring[next] = entry
        next = (next + 1) % capacity
    }

    /// Oldest first.
    var entries: [Tab.ConsoleEntry] {
        Array(ring[next...] + ring[..<next])
    }

    mutating func removeAll() {
        ring.removeAll(keepingCapacity: true)
        next = 0
    }
}

/// PNG files of snapshots: the image is taken apart on the main thread, encoded and written
/// on a background queue.
enum PNG {
    private static let queue = DispatchQueue(label: "dev.tilr.png", qos: .userInitiated)

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func write(_ image: NSImage, to file: URL) async throws {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw Failure(message: "snapshot: no image")
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    return done.resume(throwing: Failure(message: "snapshot: cannot write \(file.path)"))
                }
                CGImageDestinationAddImage(destination, cgImage, nil)
                guard CGImageDestinationFinalize(destination) else {
                    return done.resume(throwing: Failure(message: "snapshot: cannot write \(file.path)"))
                }
                done.resume()
            }
        }
    }
}
