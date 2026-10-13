import AppKit
import TilrPluginViews
import WebKit
import TilrPluginABI

/// Integration checks exercise WebKit's input path, not synthetic DOM dispatchEvent.
@MainActor
func probeBrowserAutomation(settings: BrowserSettings, host: TLRPluginHost? = nil) async throws {
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
    try await probePlacement(settings: settings)
    if let host {
        try await probeAdoption(settings: settings, host: host)
        try await probeDiscard(settings: settings, host: host)
    }
}

/// A host for the probe's own views: the real one's store identifiers (the default store is
/// made once per process from them), a view container of the probe's, the events kept.
private final class ProbeHost: NSObject, TLRPluginHost {
    let real: TLRPluginHost
    let viewContainer: NSView
    var events: [[String: Any]] = []
    init(real: TLRPluginHost, container: NSView) { self.real = real; viewContainer = container }
    var origin: String { real.origin }
    var configuration: [String: Any] { [:] }
    var storageIdentifier: UUID? { real.storageIdentifier }
    func persistentIdentifier(_ identifier: UUID) -> UUID { real.persistentIdentifier(identifier) }
    func resolveSiteURL(_ url: URL) -> URL? { nil }
    func emit(_ event: String, detail: [String: Any]) { events.append(detail) }
}

/// A page reload: a view made with a `key` is parked and adopted by the next page's `create`
/// with that key (the same WKWebView: its JS state and scroll kept, nothing loaded again,
/// `adopted: true` with the state); a view without one is made anew; with another profile
/// the parked view is not adopted.
@MainActor
private func probeAdoption(settings: BrowserSettings, host real: TLRPluginHost) async throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PluginFailure(message: message) }
    }
    let page = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let window = NSWindow(contentRect: page.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page
    window.orderFront(nil)
    defer { window.close() }
    let host = ProbeHost(real: real, container: page)
    var probeSettings = settings
    probeSettings.adoptGrace = max(settings.adoptGrace, 5)
    let views = WebViewHost(settings: probeSettings)
    views.host = host
    defer { views.removeAll() }
    let html = "data:text/html,<body style='height:5000px'><script>window.mark=Math.random()</script>tall</body>"
    let place: [String: Any] = ["x": 10.0, "y": 10.0, "width": 300.0, "height": 200.0, "visible": true, "z": 0, "holes": [[String: Any]]()]
    views.receive(["op": "create", "id": "p1", "key": "probe-window", "url": html])
    views.receive(["op": "create", "id": "p2", "url": html])
    views.receive(["op": "place", "id": "p1"].merging(place) { $1 })
    guard let first = views.view("p1"), let plain = views.view("p2") else { throw PluginFailure(message: "adoption: views not made") }
    for _ in 0..<100 where first.webView.isLoading || first.webView.url == nil || plain.webView.isLoading {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let mark = try await first.automation.evaluate("scrollTo(0, 500); return window.mark", page: true) as? Double
    try check(mark != nil, "adoption: no page in the keyed view")
    views.park()
    try check(views.parkedKeys == ["probe-window"] && views.view("p1") == nil, "adoption: keyed view not parked (\(views.parkedKeys))")
    try check(first.surface.isHidden && first.parked, "adoption: parked view shown")
    host.events.removeAll()
    views.receive(["op": "create", "id": "n1", "key": "probe-window", "url": "about:blank"])
    views.receive(["op": "create", "id": "n2", "url": html])
    try check(views.view("n1") === first, "adoption: create with the key made a new view")
    try check(views.view("n2") !== plain, "adoption: a view without a key was kept")
    try check(views.parkedKeys.isEmpty, "adoption: still parked after adoption")
    let adopted = host.events.first { $0["id"] as? String == "n1" }
    try check(adopted?["adopted"] as? Bool == true && (adopted?["url"] as? String ?? "").hasPrefix("data:"), "adoption: no adopted report with the state, got \(String(describing: adopted))")
    try check(!first.webView.isLoading, "adoption: the adopted view loads again")
    let after = try await first.automation.evaluate("return [window.mark, scrollY]", page: true) as? [Double]
    try check(after?.first == mark && after?.last == 500, "adoption: page state lost (\(String(describing: after)) vs mark \(String(describing: mark)))")
    views.receive(["op": "place", "id": "n1"].merging(place) { $1 })
    try check(!first.surface.isHidden, "adoption: the adopted view not shown by place")
    // Another profile: the parked view cannot be given another store, a new view instead.
    views.park()
    views.receive(["op": "create", "id": "m1", "key": "probe-window", "url": "about:blank", "profile": ["id": UUID().uuidString]])
    try check(views.view("m1") !== first && views.parkedKeys.isEmpty, "adoption: a view adopted into another profile")
    // Not adopted within the grace: disposed by the timer.
    var short = probeSettings
    short.adoptGrace = 0.2
    views.settings = short
    views.receive(["op": "create", "id": "u1", "url": "about:blank"])
    let lone = views.view("u1")
    views.receive(["op": "create", "id": "t1", "key": "probe-timer", "url": "about:blank"])
    let timed = views.view("t1")
    views.park()
    try check(views.parkedKeys == ["probe-timer", "probe-window"], "adoption: keyed views not parked (\(views.parkedKeys))")
    try check(lone?.surface.superview == nil, "adoption: a view without a key outlived the page")
    try await Task.sleep(nanoseconds: 500_000_000)
    try check(views.parkedKeys.isEmpty && timed?.surface.superview == nil, "adoption: an unadopted view outlived adopt_grace")
    // adopt_grace 0: nothing is parked.
    var none = probeSettings
    none.adoptGrace = 0
    views.settings = none
    views.receive(["op": "create", "id": "z1", "key": "probe-zero", "url": "about:blank"])
    views.park()
    try check(views.parkedKeys.isEmpty, "adoption: parked with adopt_grace 0")
    print("browser adoption: keyed view parked and adopted (same WKWebView, JS state and scrollY 500 kept, adopted: true), unkeyed made anew, another profile not adopted, unadopted disposed after the grace, adopt_grace 0 parks nothing: ok")
}

/// A view wholly under the page's holes is hidden (WebKit stops its rendering updates) and
/// still answers automation; size changes during a live resize reach the page throttled, the
/// last one always.
@MainActor
private func probePlacement(settings: BrowserSettings) async throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PluginFailure(message: message) }
    }
    let page = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let window = NSWindow(contentRect: page.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page
    window.orderFront(nil)
    defer { window.close() }
    let overlay = ViewOverlay(frame: page.bounds)
    page.addSubview(overlay)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let automation = BrowserAutomation(timeout: settings.automationTimeout, privateInput: false, inputInterval: settings.automationInputInterval)
    automation.install(configuration.userContentController)
    let web = WKWebView(frame: .zero, configuration: configuration)
    automation.webView = web
    let surface = ViewSurface(content: web, parent: overlay)
    surface.resizeInterval = settings.liveResizeInterval / 1000
    defer { surface.removeFromSuperview() }
    let rect = CGRect(x: 20, y: 20, width: 400, height: 300)
    surface.place(rect, visible: true, z: 0, holes: [])
    web.loadHTMLString("<script>window.ticks=0;(function f(){ticks++;requestAnimationFrame(f)})()</script>",
                       baseURL: URL(string: "https://tilr-probe.invalid"))
    for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
    func ticks(over seconds: Double) async throws -> Int {
        let a = try await automation.evaluate("return ticks", page: true) as? Int ?? 0
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        return (try await automation.evaluate("return ticks", page: true) as? Int ?? 0) - a
    }
    // Two floats side by side, overlapping, neither covering the view alone.
    surface.place(rect, visible: true, z: 0, holes: [CGRect(x: -5, y: -5, width: 210, height: 320), CGRect(x: 200, y: -5, width: 210, height: 320)])
    try check(surface.isHidden && web.isHiddenOrHasHiddenAncestor, "placement: a view covered by two holes is not hidden")
    try await Task.sleep(nanoseconds: 200_000_000)
    let covered = try await ticks(over: 0.5)  // evaluate answers on the hidden view
    surface.place(rect, visible: true, z: 0, holes: [CGRect(x: 0, y: 0, width: 100, height: 100)])
    try check(!surface.isHidden, "placement: a partly covered view is hidden")
    try await Task.sleep(nanoseconds: 200_000_000)
    let shown = try await ticks(over: 0.5)
    if window.occlusionState.contains(.visible) {
        try check(shown > 5 && covered <= 2, "placement: rAF \(shown) shown, \(covered) covered in 0.5 s")
    } else {
        print("placement: probe window occluded, rAF not compared (\(shown) shown, \(covered) covered)")
    }
    // A live resize: the surface follows; the first change applies, the next ones wait.
    let interval = settings.liveResizeInterval / 1000
    for width in stride(from: 390, through: 300, by: -10) {
        surface.place(CGRect(x: rect.minX, y: rect.minY, width: CGFloat(width), height: rect.height), visible: true, z: 0, holes: [])
    }
    try check(surface.frame.width == 300, "placement: the surface did not follow the rect")
    if interval > 0 { try check(web.frame.width > 300, "placement: every size change of a live resize applied at once") }
    try await Task.sleep(nanoseconds: UInt64((interval + 0.2) * 1e9))
    let width = try await automation.evaluate("return innerWidth", page: true) as? Int
    try check(web.frame.size == CGSize(width: 300, height: rect.height) && width == 300, "placement: the last size not applied (\(web.frame), innerWidth \(String(describing: width)))")
    print("browser placement: covered → hidden, rAF \(shown) → \(covered) per 0.5 s, automation on a hidden view, live resize throttled to \(Int(interval * 1000)) ms, last size applied: ok")
}

/// `browser.discard_after`: a hidden view drops its WKWebView (its picture in place, reported
/// `discarded: true`, listed so), and a `place` that shows it brings it back with its history
/// and scroll (`interactionState`) and a fresh script state; a parked view is discarded too and
/// comes back after its adoption; automation brings a hidden discarded view back, and its next
/// discard shows a picture again; the dropped WKWebView goes at once; a hidden ancestor (a
/// concealed tab) and a window ordered out count as hidden.
@MainActor
private func probeDiscard(settings: BrowserSettings, host real: TLRPluginHost) async throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PluginFailure(message: message) }
    }
    let page = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let window = NSWindow(contentRect: page.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page
    // An occluded window counts as hidden: keep the probe's in front of the others.
    window.level = .floating
    window.orderFrontRegardless()
    defer { window.close() }
    for _ in 0..<40 where !window.occlusionState.contains(.visible) { try await Task.sleep(nanoseconds: 50_000_000) }
    let windowVisible = window.occlusionState.contains(.visible)
    let host = ProbeHost(real: real, container: page)
    var probeSettings = settings
    probeSettings.discardAfter = 0.3
    probeSettings.adoptGrace = max(settings.adoptGrace, 5)
    let views = WebViewHost(settings: probeSettings)
    views.host = host
    defer { views.removeAll() }
    func html(_ name: String) -> String {
        "data:text/html,<title>\(name)</title><body style='margin:0;height:5000px;background:rgb(255,0,0)'><script>window.mark=Math.random()</script>\(name)</body>"
    }
    func place(_ visible: Bool) -> [String: Any] {
        ["x": 10.0, "y": 10.0, "width": 300.0, "height": 200.0, "visible": visible, "z": 0, "holes": [[String: Any]]()]
    }
    func settle(_ view: ChildView) async throws {
        for _ in 0..<100 where view.webView == nil || view.webView.isLoading || view.webView.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func discarded(_ view: ChildView) async throws -> Bool {
        let deadline = Date().addingTimeInterval(probeSettings.discardAfter + settings.automationTimeout)
        while view.discarded == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        return view.discarded != nil
    }
    /// The view's placeholder is a picture of the probe's red page.
    func pictured(_ view: ChildView) -> Bool {
        guard let image = view.picture?.image, image.size.width > 0, image.size.height > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        let center = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        return (center?.redComponent ?? 0) > 0.8 && (center?.greenComponent ?? 1) < 0.2
    }
    func webViews(in view: NSView) -> Int { view.subviews.reduce(view is WKWebView ? 1 : 0) { $0 + webViews(in: $1) } }
    func last(_ id: String) -> [String: Any]? { host.events.last { $0["id"] as? String == id && $0["type"] == nil } }

    views.receive(["op": "create", "id": "d1", "key": "probe-discard", "url": html("one")])
    views.receive(["op": "place", "id": "d1"].merging(place(true)) { $1 })
    guard let view = views.view("d1") else { throw PluginFailure(message: "discard: view not made") }
    try await settle(view)
    views.receive(["op": "navigate", "id": "d1", "url": html("two")])
    try await Task.sleep(nanoseconds: 100_000_000)
    try await settle(view)
    let mark = try await view.automation.evaluate("scrollTo(0, 800); return window.mark", page: true) as? Double
    try check(mark != nil && view.webView.canGoBack, "discard: no second page in the view")
    let url = view.webView.url?.absoluteString
    try await Task.sleep(nanoseconds: 300_000_000)
    // Shown: never discarded (unless the probe's window is not visible: then it counts as hidden).
    if windowVisible { try check(view.discarded == nil, "discard: a shown view was discarded") }
    weak let dropped = view.webView
    let started = Date()
    views.receive(["op": "place", "id": "d1"].merging(place(false)) { $1 })
    try check(try await discarded(view), "discard: a hidden view was not discarded after discard_after")
    let took = Date().timeIntervalSince(started)
    try check(view.webView == nil && webViews(in: page) == 0, "discard: a WKWebView is still held")
    // Nothing keeps the dropped web view (and its WebContent process) alive.
    let freed = Date()
    while dropped != nil, Date().timeIntervalSince(freed) < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
    let freedIn = Date().timeIntervalSince(freed)
    try check(dropped == nil, "discard: the dropped WKWebView is still alive 2 s after the discard")
    let listed = views.browserList().first { $0["id"] as? String == "d1" }
    try check(listed?["discarded"] as? Bool == true && listed?["url"] as? String == url, "discard: browser list \(String(describing: listed))")
    try check(last("d1")?["discarded"] as? Bool == true && last("d1")?["canGoBack"] as? Bool == true, "discard: no report with discarded: true, got \(String(describing: last("d1")))")
    try check(pictured(view), "discard: no picture of the page")
    // Shown again: back with its history and scroll, script state new.
    let shown = Date()
    views.receive(["op": "place", "id": "d1"].merging(place(true)) { $1 })
    try check(view.discarded == nil && view.webView != nil && view.picture != nil, "discard: place did not bring the view back under its picture")
    let deadline = Date().addingTimeInterval(settings.automationTimeout)
    while view.picture != nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    let restore = Date().timeIntervalSince(shown)
    try check(view.picture == nil, "discard: the picture stayed after the load")
    try await Task.sleep(nanoseconds: 100_000_000)
    let after = try await view.automation.evaluate("return [scrollY, window.mark ?? null, document.title]", page: true) as? [Any]
    try check(after?.first as? Double == 800, "discard: scrollY not restored (\(String(describing: after)))")
    try check((after?[1] as? Double) != mark, "discard: script state survived (mark \(String(describing: mark)))")
    try check(view.webView.canGoBack && view.webView.url?.absoluteString == url, "discard: history not restored")
    try check(last("d1")?["discarded"] as? Bool == false, "discard: no report with discarded: false")
    // Automation on a hidden discarded view brings it back for the call.
    views.receive(["op": "place", "id": "d1"].merging(place(false)) { $1 })
    try check(try await discarded(view), "discard: hidden again, not discarded")
    let value = try await views.browserCommand(["action": "evaluate", "browser": "d1", "js": "return scrollY"])
    try check(value["value"] as? Double == 800 && view.discarded == nil, "discard: automation on a discarded view: \(value)")
    // Parked: discarded too; adopted, it comes back on the new page's place.
    try check(try await discarded(view), "discard: hidden after automation, not discarded again")
    try check(view.picture?.image.map { $0.size.width > 0 } == true, "discard: no picture on the second discard")
    let secondPicture = pictured(view) ? "the page" : "the last one kept"
    views.receive(["op": "place", "id": "d1"].merging(place(true)) { $1 })
    while view.picture != nil, Date() < deadline.addingTimeInterval(settings.automationTimeout) { try await Task.sleep(nanoseconds: 20_000_000) }
    views.park()
    try check(try await discarded(view), "discard: a parked view was not discarded")
    views.receive(["op": "create", "id": "e1", "key": "probe-discard", "url": "about:blank"])
    try check(views.view("e1") === view && view.discarded != nil, "discard: the discarded parked view was not adopted as is")
    views.receive(["op": "place", "id": "e1"].merging(place(true)) { $1 })
    try check(view.webView != nil, "discard: the adopted view did not come back on place")
    try await settle(view)
    try check(view.webView.url?.absoluteString == url, "discard: the adopted view lost its page")
    // A hidden ancestor (the host concealing the tab): hidden, discarded; shown, back.
    page.isHidden = true
    try check(try await discarded(view), "discard: a view in a hidden ancestor was not discarded")
    page.isHidden = false
    try check(windowVisible ? view.webView != nil : true, "discard: the ancestor shown again did not bring the view back")
    try await settle(view)
    // A window that is not visible (ordered out: as minimized or on another Space).
    var occlusion = "window occlusion unchecked (probe window not visible)"
    if windowVisible {
        window.orderOut(nil)
        try check(try await discarded(view), "discard: a view in a window ordered out was not discarded")
        window.orderFrontRegardless()
        let back = Date().addingTimeInterval(settings.automationTimeout)
        while view.discarded != nil, Date() < back { try await Task.sleep(nanoseconds: 50_000_000) }
        try check(view.discarded == nil, "discard: the window shown again did not bring the view back")
        try await settle(view)
        occlusion = "window ordered out discarded, back when shown"
    }
    // Playing media keeps a hidden view; paused, it goes.
    // A quiet looping tone (a muted or silent video is paused by WebKit once it is not seen).
    let tone = "const n=8000,b=new ArrayBuffer(44+n*2),d=new DataView(b),w=(o,t)=>[...t].forEach((c,i)=>d.setUint8(o+i,c.charCodeAt(0)));w(0,'RIFF');d.setUint32(4,36+n*2,true);w(8,'WAVEfmt ');d.setUint32(16,16,true);d.setUint16(20,1,true);d.setUint16(22,1,true);d.setUint32(24,8000,true);d.setUint32(28,16000,true);d.setUint16(32,2,true);d.setUint16(34,16,true);w(36,'data');d.setUint32(40,n*2,true);for(let i=0;i<n;i++)d.setInt16(44+i*2,Math.sin(i/4)*40,true);const a=document.querySelector('audio');a.src=URL.createObjectURL(new Blob([b],{type:'audio/wav'}));a.loop=true;a.play().catch(()=>{})"
    views.receive(["op": "create", "id": "m1", "url": "data:text/html,<audio></audio><script>" + tone + "</script>"])
    views.receive(["op": "place", "id": "m1"].merging(place(true)) { $1 })
    guard let media = views.view("m1") else { throw PluginFailure(message: "discard: media view not made") }
    try await settle(media)
    try await Task.sleep(nanoseconds: 300_000_000)
    let plays = try await media.automation.evaluate("const v = document.querySelector('audio'); return !v.paused && !v.ended", page: true) as? Bool == true
    var mediaNote = "media not playable here, unchecked"
    if plays {
        views.receive(["op": "place", "id": "m1"].merging(place(false)) { $1 })
        try await Task.sleep(nanoseconds: UInt64((probeSettings.discardAfter * 3 + 0.5) * 1e9))
        try check(media.discarded == nil, "discard: a view playing media was discarded")
        _ = try await media.automation.evaluate("document.querySelector('audio').pause()", page: true)
        try check(try await discarded(media), "discard: a paused media view was not discarded")
        mediaNote = "playing media kept, paused discarded"
    }
    print(String(format: "browser discard: hidden → discarded in %.2f s (no WKWebView, freed in %.2f s, picture of the page, discarded: true), shown → back in %.2f s with history and scrollY 800, script state new; automation and adoption bring it back, second discard pictures %@; hidden ancestor discarded, back when shown; %@; %@: ok", took, freedIn, restore, secondPicture, occlusion, mediaNote))
}
