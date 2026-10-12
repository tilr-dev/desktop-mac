import AppKit
import WebKit

/// Integration checks exercise WebKit's input path, not synthetic DOM dispatchEvent.
@MainActor
func probeBrowserAutomation(settings: BrowserSettings) async throws {
    let timeout = settings.automationTimeout
    let automation = BrowserAutomation(timeout: timeout, privateInput: true, inputInterval: settings.automationInputInterval)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    automation.install(configuration.userContentController)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
    automation.webView = web
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    web.loadHTMLString("""
    <style>body{margin:0}button{width:150px;height:60px}#scroll{height:100px;overflow:auto}#tall{height:1000px}iframe{width:300px;height:100px}</style>
    <button id="button">Click</button><div id="scroll"><div id="tall">Scroll</div></div>
    <iframe src="data:text/html,<button id='inside' onclick='window.clicked=event.isTrusted'>Frame</button>"></iframe>
    <script>window.events=[];for(const type of ['click','mousemove','wheel'])document.addEventListener(type,e=>events.push({type,trusted:e.isTrusted}));</script>
    """, baseURL: URL(string: "https://tilr-probe.invalid"))
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PluginFailure(message: message) }
    }
    do {
        for _ in 0..<100 {
            if !web.isLoading, await automation.frameList().count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let frames = await automation.frameList()
        try check(frames.count == 2, "browser: main and cross-origin frame registration")
        let result = try await automation.evaluate("return await Promise.resolve(args.value + 1)", arguments: ["args": ["value": 41]], page: true)
        try check(result as? Int == 42, "browser: async evaluation")
        for action in ["hover", "click"] {
            let target: [String: Any] = ["selector": "#button"]
            try await automation.input(action, at: try await automation.point(target), request: target)
        }
        let target: [String: Any] = ["selector": "#scroll", "deltaY": 150]
        let scrolled = try await automation.evaluate("return __tilrBrowser.scroll(target)", arguments: ["target": target])
        print("browser scroll:", scrolled)
        let deadline = Date().addingTimeInterval(timeout)
        var events: [[String: Any]] = []
        repeat {
            events = try await automation.evaluate("return events", page: true) as? [[String: Any]] ?? []
            if ["mousemove", "click"].allSatisfy({ type in events.contains { $0["type"] as? String == type } }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        print("browser scrollTop:", try await automation.evaluate("return document.querySelector('#scroll').scrollTop", page: true))
        print("browser events:", events)
        for type in ["mousemove", "click"] {
            try check(events.contains { $0["type"] as? String == type && $0["trusted"] as? Bool == true }, "browser: trusted \(type), got \(events)")
        }
        let scroll = try await automation.evaluate("return document.querySelector('#scroll').scrollTop", page: true) as? Double ?? 0
        try check(scroll > 0, "browser: container scrolled")
        let frame = frames.first { $0["main"] as? Bool == false }!["id"] as! String
        let inside: [String: Any] = ["selector": "#inside", "frame": frame]
        try await automation.input("click", at: try await automation.point(inside), request: inside)
        try await Task.sleep(nanoseconds: 100_000_000)
        let clicked = try await automation.evaluate("return window.clicked", frame: frame, page: true)
        try check(clicked as? Bool == true, "browser: cross-origin trusted click")
        let snap = try await automation.evaluate("return __tilrBrowser.snapshot()", frame: frame) as! [String: Any]
        let ref = (snap["elements"] as! [[String: Any]])[0]["ref"] as! String
        _ = try await automation.evaluate("document.querySelector('button').remove()", frame: frame, page: true)
        var rejected = false
        do { _ = try await automation.point(["frame": frame, "ref": ref]) }
        catch { rejected = true }
        try check(rejected, "browser: stale ref accepted")
        print("browser automation: async JS, trusted click/hover, DOM container scroll, cross-origin iframe, stale ref: ok")
    } catch {
        throw error
    }
}
