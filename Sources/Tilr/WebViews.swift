import AppKit
import Network
import WebKit

/// The page's web views (the `webviews` plugin of the web repo, its native backend): a WKWebView
/// per view, a subview of the tab's web view, placed where the page says the view's host element
/// is. The page posts `{ op, id, … }` to `webkit.messageHandlers.tilrWebViews`:
///
///   create   url profile?   a new view, loading `url`; `profile` `{ id, proxy?, localhost? }` gives
///            it a data store of its own (see Profiles.swift): `id` a UUID naming the store, `proxy`
///            `{ kind: 'socks5' | 'http', host, port, user?, pass?, match?, exclude? }` or
///            `{ kind: 'tunnel', url, token, match?, exclude? }` (a tilr server's `/socks`, bridged
///            by a local listener, Tunnel.swift), `localhost` the host a loopback address goes
///            to; the view loads once the store has the proxy
///   place    x y width height visible z holes   the host's rect in the page (CSS px, from the
///            top left); `z` orders the views as the page stacks their hosts; `holes` (rects
///            relative to the view) are where the page draws a window over the host
///   navigate url
///   back | forward | reload | stop
///   dispose
///
/// and the app answers with a `tilr-webview` CustomEvent on the page's `window`, `detail` being
/// `{ id, url, title, loading, progress, canGoBack, canGoForward, error, proxy? }` on every change
/// of the view's state (`proxy` `{ kind, error? }` for a view with one: `error` is a tunnel's last
/// failed handshake, `'401 bad token'`, gone after one that went through; WebKit tells nothing
/// of a socks5 or http proxy), `{ id, type: 'open', open: url }` when the view's page asks for a
/// new window (`target=_blank`, `window.open`), or `{ id, type: 'press' }` on a mouse button down in the
/// view (the page never sees it: the view takes the event; the page focuses the window on it).
/// Views go when the page navigates (a reload), and
/// with the tab. The views are above the page, in an overlay of their own (so that ordering
/// them never touches WebKit's subviews); a view is masked out at its holes and lets the mouse
/// through there, so a float the page draws over a tiled view's host is seen and clicked as the
/// page stacks it. What the page draws over a host and does not report (a menu) stays covered.
final class WebViewHost: NSObject, WKScriptMessageHandler {
    static let name = "tilrWebViews"
    static let event = "tilr-webview"

    weak var tab: Tab?
    /// `browser:` in the config; read when a view is made.
    var settings: Config.Browser
    private var views: [String: ChildView] = [:]

    /// Agent access stays on the native control socket, never on the website's JS bridge.
    func browserList() -> [[String: Any]] {
        views.values.sorted { $0.id < $1.id }.map {
            ["id": $0.id, "url": $0.webView.url?.absoluteString ?? "", "title": $0.webView.title ?? "",
             "loading": $0.webView.isLoading, "visible": !$0.webView.isHidden]
        }
    }

    func browser(_ id: String) throws -> ChildView {
        guard let view = views[id] else { throw ControlServer.Failure(message: "no browser \(id); call browser_list") }
        return view
    }
    /// The views' container over the page's web view, made with the first view.
    private var overlay: PassthroughView?

    init(settings: Config.Browser) {
        self.settings = settings
    }

    private func overlay(in page: NSView) -> PassthroughView {
        if let overlay, overlay.superview === page { return overlay }
        overlay?.removeFromSuperview()
        let made = PassthroughView(frame: page.bounds)
        made.autoresizingMask = [.width, .height]
        page.addSubview(made)
        overlay = made
        return made
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let body = message.body as? [String: Any], let op = body["op"] as? String, let id = body["id"] as? String else { return }
        switch op {
        case "create":
            views[id]?.remove()
            // The page's origin is what a tunnel's handshake shows the server (tilr://<app>).
            let origin = tab.app.origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lease = Profiles.shared.join(Profile(body["profile"]), origin: origin, chunk: settings.tunnelChunk)
            let view = ChildView(id: id, settings: settings, lease: lease, parent: overlay(in: tab.webView)) { [weak tab] detail in
                tab?.send(event: WebViewHost.event, detail: detail)
            }
            views[id] = view
            view.load(body["url"] as? String ?? "about:blank")
        case "place":
            guard let x = body["x"] as? Double, let y = body["y"] as? Double, let width = body["width"] as? Double, let height = body["height"] as? Double else { return }
            let holes = (body["holes"] as? [[String: Any]] ?? []).compactMap { hole -> CGRect? in
                guard let x = hole["x"] as? Double, let y = hole["y"] as? Double, let width = hole["width"] as? Double, let height = hole["height"] as? Double else { return nil }
                return CGRect(x: x, y: y, width: width, height: height)
            }
            views[id]?.place(CGRect(x: x, y: y, width: width, height: height), visible: body["visible"] as? Bool ?? true, z: body["z"] as? Int ?? 0, holes: holes)
            overlay?.order()
        case "navigate":
            views[id]?.load(body["url"] as? String ?? "about:blank")
        case "back": views[id]?.webView.goBack()
        case "forward": views[id]?.webView.goForward()
        case "reload": views[id]?.webView.reload()
        case "stop": views[id]?.webView.stopLoading()
        case "dispose":
            views[id]?.remove()
            views[id] = nil
        default:
            print("webviews: unknown op \(op)")
        }
    }

    /// The page is going (a reload, the tab closing): every view with it.
    func removeAll() {
        for view in views.values { view.remove() }
        views.removeAll()
    }
}

/// The views' container: itself invisible to the mouse (a hit on none of its subviews goes to
/// the page), and it keeps its subviews in the order of their `z`.
final class PassthroughView: NSView {
    /// From the top left, as the page's coordinates are.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Subviews sorted by `z`, lowest first (at the bottom); only when the order is wrong.
    func order() {
        let ordered = subviews.sorted { ($0 as? ChildWebView)?.z ?? 0 < ($1 as? ChildWebView)?.z ?? 0 }
        guard ordered.elementsEqual(subviews, by: ===) else { return sortSubviews({ a, b, _ in
            let za = (a as? ChildWebView)?.z ?? 0, zb = (b as? ChildWebView)?.z ?? 0
            return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
        }, context: nil) }
    }
}

/// The web view of a child: its order among the views, and the holes, where the page's windows
/// above its host are: masked out, and the mouse goes through to the page there.
final class ChildWebView: WKWebView {
    var z = 0
    var holes: [CGRect] = [] { didSet { if holes != oldValue { mask() } } }
    /// A mouse button went down in the view (any button): the page's window wants the focus.
    var pressed: (() -> Void)?

    override func layout() {
        super.layout()
        mask()
    }

    override func mouseDown(with event: NSEvent) {
        pressed?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        pressed?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        pressed?()
        super.otherMouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let inside = convert(point, from: superview)
        if holes.contains(where: { $0.contains(inside) }) { return nil }
        return super.hitTest(point)
    }

    /// The layer's mask: everything but the holes (an even-odd path of the bounds and the holes
    /// made disjoint: two holes that overlap, a float and a menu over it, would mask the overlap
    /// back in), none without holes.
    private func mask() {
        guard let layer else { return }
        guard !holes.isEmpty else { layer.mask = nil; return }
        let shape = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        shape.frame = layer.bounds
        shape.fillRule = .evenOdd
        let path = CGMutablePath()
        path.addRect(layer.bounds)
        // The holes are from the top left (the view is flipped); so is the layer, unless AppKit
        // left its geometry the Core Animation way, from the bottom left.
        let flipped = layer.isGeometryFlipped || layer.contentsAreFlipped()
        let rects = holes.map { hole in
            (flipped ? hole : CGRect(x: hole.minX, y: layer.bounds.height - hole.maxY, width: hole.width, height: hole.height)).intersection(layer.bounds)
        }
        for rect in disjoint(rects) { path.addRect(rect) }
        shape.path = path
        layer.mask = shape
    }
}

/// One view: the WKWebView, its place, and the reports to the page. KVO on the web view's
/// url / title / loading / progress / history, coalesced into one report per run of the loop.
/// A view with a profile has the profile's store; with a proxy, it loads nothing before the
/// store has the proxy (a tunnel's listener has a port), so no connection of it goes direct.
final class ChildView: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let webView: ChildWebView
    let automation: BrowserAutomation
    private weak var parent: NSView?
    private let report: ([String: Any]) -> Void
    private var observers: [NSKeyValueObservation] = []
    private var error: String?
    private var pending = false
    private let lease: Lease
    /// A tunnel's last failed handshake (or its listener's failure); nil once one went through.
    private var proxyError: String?
    /// Until the store has the proxy: the URL to load then.
    private var held = true
    private var waiting: String?

    init(id: String, settings: Config.Browser, lease: Lease, parent: NSView, report: @escaping ([String: Any]) -> Void) {
        self.id = id
        self.parent = parent
        self.report = report
        self.lease = lease
        let configuration = WKWebViewConfiguration()
        automation = BrowserAutomation(timeout: settings.automationTimeout, privateInput: settings.automationPrivateInput, inputInterval: settings.automationInputInterval)
        automation.install(configuration.userContentController)
        // The profile's store, or the default one: cookies and logins shared by every view
        // without a profile. Both kept across launches.
        configuration.websiteDataStore = lease.store
        configuration.preferences.isElementFullscreenEnabled = true
        webView = ChildWebView(frame: .zero, configuration: configuration)
        super.init()
        automation.webView = webView
        webView.wantsLayer = true
        webView.pressed = { [weak self] in
            guard let self else { return }
            self.report(["id": self.id, "type": "press"])
        }
        if !settings.userAgent.isEmpty { webView.customUserAgent = settings.userAgent }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.isHidden = true
        webView.underPageBackgroundColor = .white
        parent.addSubview(webView)
        let changed: (WKWebView, Any) -> Void = { [weak self] _, _ in self?.schedule() }
        observers = [
            webView.observe(\.url, changeHandler: changed),
            webView.observe(\.title, changeHandler: changed),
            webView.observe(\.isLoading, changeHandler: changed),
            webView.observe(\.estimatedProgress, changeHandler: changed),
            webView.observe(\.canGoBack, changeHandler: changed),
            webView.observe(\.canGoForward, changeHandler: changed),
        ]
        lease.status = { [weak self] error in
            guard let self, proxyError != error else { return }
            proxyError = error
            schedule()
        }
        lease.ready { [weak self] failure in
            guard let self else { return }
            held = false
            if let failure {
                // No proxy, no load: the page would go direct.
                proxyError = failure
                error = "proxy: \(failure)"
                waiting = nil
                return schedule()
            }
            if let waiting { load(waiting) }
            waiting = nil
        }
    }

    func load(_ text: String) {
        guard let url = URL(string: text) else {
            error = "not a URL: \(text)"
            schedule()
            return
        }
        if held {
            waiting = text
            return
        }
        error = nil
        webView.load(URLRequest(url: local(url) ?? url))
    }

    /// `url` at the profile's `localhost` host when it is at a loopback one (`localhost`, `127.*`,
    /// `[::1]`, which WebKit never sends through a proxy), port, path and query kept; else nil.
    private func local(_ url: URL) -> URL? {
        guard let to = lease.profile?.localhost, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        let loopback = host == "localhost" || host == "::1" || host == "[::1]" || IPv4Address(host)?.rawValue.first == 127
        guard loopback, to.lowercased() != host, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = to
        return components.url
    }

    /// `rect` is the host's place in the page: CSS px from the top left, which is the web view's
    /// coordinate system (WKWebView is flipped on macOS; the check keeps it right either way).
    /// `holes` are relative to the view, from its top left, as the view's own flipped bounds.
    func place(_ rect: CGRect, visible: Bool, z: Int, holes: [CGRect]) {
        guard let parent else { return }
        let y = parent.isFlipped ? rect.minY : parent.bounds.height - rect.minY - rect.height
        webView.frame = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
        webView.isHidden = !visible
        webView.z = z
        webView.holes = holes
    }

    func remove() {
        lease.end()
        observers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    // MARK: Reports

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.report(self.state)
        }
    }

    private var state: [String: Any] {
        var state: [String: Any] = [
            "id": id,
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
            "loading": webView.isLoading,
            "progress": webView.estimatedProgress,
            "canGoBack": webView.canGoBack,
            "canGoForward": webView.canGoForward,
            "error": error ?? NSNull(),
        ]
        if let proxy = lease.profile?.proxy {
            state["proxy"] = proxyError.map { ["kind": proxy.name, "error": $0] } ?? ["kind": proxy.name]
        }
        return state
    }

    private func failed(_ error: Error) {
        let nsError = error as NSError
        // A load replaced by the next one, or stopped by the policy (a link handed to the system),
        // is not a failure. 102: WKErrorFrameLoadInterruptedByPolicyChange.
        guard nsError.code != NSURLErrorCancelled, !(nsError.domain == WKError.errorDomain && nsError.code == 102) else { return }
        self.error = error.localizedDescription
        schedule()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        schedule()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// Links to other apps (mailto:, a custom scheme) go to the system; the web stays here. A page
    /// at a loopback address goes to the profile's `localhost` host instead, when it has one.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.allow) }
        if navigationAction.targetFrame?.isMainFrame == true, let moved = local(url) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: moved))
            return
        }
        if ["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme) { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: WKUIDelegate

    /// A new window: the page decides where it goes (a new browser window, or this view).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString, !url.isEmpty, url != "about:blank" {
            report(["id": id, "type": "open", "open": url])
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? ""
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? ""
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? ""
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}

/// `rects` as rects that do not overlap and cover the same area: each one less the ones before
/// it (a rect less another is up to four: the strips above and below it, left and right of it).
func disjoint(_ rects: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for rect in rects where !rect.isEmpty {
        var pieces = [rect]
        for taken in out {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(taken)
                if cut.isNull || cut.isEmpty { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
        out += pieces
    }
    return out
}
