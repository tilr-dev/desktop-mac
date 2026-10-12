import AppKit
import Network
import WebKit

/// Tilr Control: how an agent (or `tilr ctl`, or `tilr mcp`) drives the running app. A server on
/// a unix socket (`control.socket` in the config), one JSON object per line each way:
///
///   { "cmd": "apps" }                               the apps (tabs) and which one is current
///   { "cmd": "switch", "app": "Notes" }             show that app
///   { "cmd": "reload" }                             reload the page
///   { "cmd": "snapshot", "path": "~/x.png" }        a picture of the page, as the window shows it
///   { "cmd": "console", "clear": false }            the page's console.* and errors, oldest first
///   { "cmd": "eval", "js": "return 1 + 1" }         the body of an async function in the page
///   { "cmd": "call", "service": "plugins", "method": "toggle", "args": ["counter"] }
///   { "cmd": "debug", "action": "status" }         Performance service: enabled, react (the page's
///                                                   build), mechanism, active (a page recording), dir,
///                                                   recording (a CLI record); mechanism 'none' + reason
///                                                   while the page loads or without the plugin
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
///
/// `call` runs a method of a service of the page's cordis root (`window.tilr.root.get(service)`):
/// `plugins.list / toggle / reload`, `layout.list / open / close / float / tile`,
/// `windows.list`, and whatever other plugins provide. That is the whole control surface: a
/// plugin that provides a service is driven the same way, with nothing added here.
///
/// Every command takes `"app"` (an app's name; the current one by default) and `"id"` (echoed).
/// The reply is `{ "id", "ok": true, …result }` or `{ "id", "ok": false, "error": "…" }`. Values
/// cross as JSON: a result the page cannot stringify comes back as a string.
final class ControlServer {
    let path: String
    private let tabs: () -> [Tab]
    private let current: () -> Tab?
    private let select: (Tab) -> Void
    private let debug: DebugMode
    private var listener: NWListener?

    init(path: String, tabs: @escaping () -> [Tab], current: @escaping () -> Tab?, select: @escaping (Tab) -> Void, debug: DebugMode) {
        self.path = path
        self.tabs = tabs
        self.current = current
        self.select = select
        self.debug = debug
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
    private func run(_ cmd: String, _ request: [String: Any]) async throws -> [String: Any] {
        func tab() throws -> Tab {
            if let name = request["app"] as? String {
                guard let tab = tabs().first(where: { $0.app.name == name }) else {
                    throw Failure(message: "no app \"\(name)\"; the apps: \(tabs().map(\.app.name).joined(separator: ", "))")
                }
                return tab
            }
            guard let tab = current() else { throw Failure(message: "no app") }
            return tab
        }
        switch cmd {
        case "apps":
            return ["apps": tabs().map { tab -> [String: Any] in
                ["name": tab.app.name, "site": tab.app.root.path, "url": tab.webView.url?.absoluteString ?? "", "current": tab === current()]
            }]
        case "switch":
            let tab = try tab()
            select(tab)
            return ["app": tab.app.name]
        case "reload":
            let tab = try tab()
            tab.reload()
            return ["app": tab.app.name]
        case "snapshot":
            guard let path = request["path"] as? String else { throw Failure(message: "snapshot: no path") }
            let tab = try tab()
            let image = try await tab.webView.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { throw Failure(message: "snapshot: no image") }
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try png.write(to: file)
            return ["path": file.path, "width": Int(image.size.width), "height": Int(image.size.height)]
        case "console":
            let tab = try tab()
            let messages = tab.console.map { ["time": $0.time, "type": $0.type, "text": $0.text] as [String: Any] }
            if request["clear"] as? Bool == true { tab.console.removeAll() }
            return ["messages": messages]
        case "eval":
            guard let js = request["js"] as? String else { throw Failure(message: "eval: no js") }
            // An expression is returned; a body with a `return` of its own runs as written.
            let body = js.range(of: #"\breturn\b"#, options: .regularExpression) == nil ? "return (\(js))" : js
            return ["value": try await evaluate(try tab(), body: body, arguments: [:])]
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
            return ["value": try await evaluate(try tab(), body: body, arguments: ["service": service, "method": method, "args": args])]
        case "debug":
            return try await debugCommand(try tab(), request)
        case "native-plugins":
            return ["plugins": try tab().nativePlugins.status()]
        case "native-call":
            guard let service = request["service"] as? String else { throw Failure(message: "native-call: service required") }
            return try await tab().nativePlugins.request(service: service, body: request["request"] as? [String: Any] ?? [:])
        case "browser":
            return try await tab().nativePlugins.request(service: "browser", body: request)
        default:
            throw Failure(message: "unknown cmd \"\(cmd)\"; one of apps, switch, reload, snapshot, console, eval, call, debug, browser")
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
            if !tab.isLoaded {
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
/// on). A separate object: the content controller retains its handlers, the tab must not retain itself.
final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    static let name = "tilrConsole"
    weak var tab: Tab?

    /// Wraps console.* and reports window errors, at document start, in every frame.
    static let script = """
        (() => {
          const post = (type, args) => {
            const text = args.map(a => {
              if (typeof a === 'string') return a
              if (a instanceof Error) return a.stack || a.message
              try { return JSON.stringify(a) ?? String(a) } catch { return String(a) }
            }).join(' ')
            try { window.webkit.messageHandlers.\(name).postMessage({ type, text }) } catch {}
          }
          for (const type of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[type]
            console[type] = (...args) => { post(type, args); original.apply(console, args) }
          }
          window.addEventListener('error', e => post('pageerror', [e.message]))
          window.addEventListener('unhandledrejection', e => post('pageerror', [e.reason instanceof Error ? e.reason.stack || e.reason.message : String(e.reason)]))
        })()
        """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let body = message.body as? [String: Any] else { return }
        tab.log(type: body["type"] as? String ?? "log", text: body["text"] as? String ?? "")
    }
}
