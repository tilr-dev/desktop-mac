import AppKit
import TilrPluginABI
import TilrPluginViews
import Network
import WebKit

/// The page's web views (the `webviews` plugin of the web repo, its native backend): a WKWebView
/// per view, a subview of the tab's web view, placed where the page says the view's host element
/// is. The page posts `{ op, id, … }` to `webkit.messageHandlers.tilrWebViews`:
///
///   create   url profile? key?   a new view, loading `url`; `profile` `{ id, proxy?, localhost? }` gives
///            it a data store of its own (see Profiles.swift): `id` a UUID naming the store, `proxy`
///            `{ kind: 'socks5' | 'http', host, port, user?, pass?, match?, exclude? }` or
///            `{ kind: 'tunnel', url, token, match?, exclude? }` (a tilr server's `/socks`, bridged
///            by a local listener, Tunnel.swift), `localhost` the host a loopback address goes
///            to; the view loads once the store has the proxy. `key`, a string the page keeps
///            for the same logical view across its reloads (the browser window's id): see
///            parking below
///   place    x y width height visible z holes   the host's rect in the page (CSS px, from the
///            top left); `z` orders the views as the page stacks their hosts; `holes` (rects
///            relative to the view) are where the page draws a window over the host
///   navigate url
///   back | forward | reload | stop
///   dispose
///
/// and the app answers with a `tilr-webview` CustomEvent on the page's `window`, `detail` being
/// `{ id, url, title, loading, progress, canGoBack, canGoForward, error, discarded, proxy? }` on every change
/// of the view's state (`proxy` `{ kind, error? }` for a view with one: `error` is a tunnel's last
/// failed handshake, `'401 bad token'`, gone after one that went through; WebKit tells nothing
/// of a socks5 or http proxy), `{ id, type: 'open', open: url }` when the view's page asks for a
/// new window (`target=_blank`, `window.open`), or `{ id, type: 'press' }` on a mouse button down in the
/// view (the page never sees it: the view takes the event; the page focuses the window on it).
/// `discarded` is true while a view hidden for `browser.discard_after` seconds has released its
/// web content (its last picture in place; see ChildView), false again once it is shown.
/// When the page navigates (a reload, a rebuild of the site), a view made with a `key` is
/// parked: hidden, its media suspended, left out of `browser_list`, reporting nothing, kept for
/// `browser.adopt_grace` seconds. A `create` of the new page with the same `key` (and the same
/// profile) adopts it: the view takes the new id, loads nothing (it shows what it showed, its
/// scroll, forms and script state kept), resumes its media, shows again on the next `place`,
/// and its first report carries `adopted: true` with the whole state (url, title, history…);
/// the create's `url` is ignored, the parked view being at least as recent as anything the page
/// saved. A view not adopted in time, every view without a key, and every view with
/// `adopt_grace: 0` goes, as with the tab. The views are above the page, in an overlay of their own (so that ordering
/// them never touches WebKit's subviews); a view is masked out at its holes and lets the mouse
/// through there, so a float the page draws over a tiled view's host is seen and clicked as the
/// page stacks it. What the page draws over a host and does not report (a menu) stays covered.
final class WebViewHost: NSObject {
    static let name = "tilrWebViews"
    static let event = "tilr-webview"

    weak var host: TLRPluginHost?
    /// `browser:` in the config; read when a view is made, except the live resize and progress
    /// intervals and `discard_after`, which the views (parked ones too) take on a config reload.
    var settings: BrowserSettings {
        didSet { for view in Array(views.values) + Array(parked.values) { view.apply(settings) } }
    }
    private var views: [String: ChildView] = [:]
    /// Views of a page that navigated, by their `key`, waiting to be adopted; and their timers.
    private var parked: [String: ChildView] = [:]
    private var parkTimers: [String: Timer] = [:]

    /// Agent access stays on the native control socket, never on the website's JS bridge.
    func browserList() -> [[String: Any]] {
        views.values.sorted { $0.id < $1.id }.map {
            let state = $0.state
            return ["id": $0.id, "url": state["url"]!, "title": state["title"]!, "loading": state["loading"]!,
                    "visible": $0.webView.map { !$0.isHiddenOrHasHiddenAncestor } ?? false, "discarded": state["discarded"]!]
        }
    }

    func browser(_ id: String) throws -> ChildView {
        guard let view = views[id] else { throw PluginFailure(message: "no browser \(id); call browser_list") }
        return view
    }
    /// The views' container over the page's web view, made with the first view.
    private var overlay: ViewOverlay?

    init(settings: BrowserSettings) {
        self.settings = settings
    }

    private func overlay(in page: NSView) -> ViewOverlay {
        if let overlay, overlay.superview === page { return overlay }
        overlay?.removeFromSuperview()
        let made = ViewOverlay(frame: page.bounds)
        made.autoresizingMask = [.width, .height]
        page.addSubview(made)
        overlay = made
        return made
    }

    func receive(_ body: [String: Any]) {
        guard let host, let op = body["op"] as? String, let id = body["id"] as? String else { return }
        switch op {
        case "create":
            views[id]?.remove()
            let key = (body["key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let profile = (body["profile"] as? NSDictionary) ?? NSDictionary()
            if let key, let view = unpark(key) {
                // Another store or proxy cannot be given to a made view: a new one instead.
                if view.profile.isEqual(profile) {
                    views[id] = view
                    view.adopt(id: id, parent: overlay(in: host.viewContainer))
                    return
                }
                view.remove()
            }
            // The page's origin is what a tunnel's handshake shows the server (tilr://<app>).
            let origin = host.origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lease = Profiles.shared.join(Profile(body["profile"]), host: host, origin: origin, chunk: settings.tunnelChunk)
            let view = ChildView(id: id, key: key, profile: profile, settings: settings, lease: lease, parent: overlay(in: host.viewContainer)) { [weak host] detail in
                host?.emit(WebViewHost.event, detail: detail)
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
        case "navigate":
            views[id]?.load(body["url"] as? String ?? "about:blank")
        case "back": views[id]?.goBack()
        case "forward": views[id]?.goForward()
        case "reload": views[id]?.reload()
        case "stop": views[id]?.stopLoading()
        case "dispose":
            views[id]?.remove()
            views[id] = nil
        default:
            print("webviews: unknown op \(op)")
        }
    }

    /// The page navigated (a reload): the views with a key wait `adopt_grace` seconds for the
    /// new page to adopt them (one per key: a second view of a key goes), the others go.
    func park() {
        let grace = settings.adoptGrace
        for view in views.values {
            guard let key = view.key, grace > 0, parked[key] == nil else { view.remove(); continue }
            view.park()
            parked[key] = view
            let timer = Timer(timeInterval: grace, repeats: false) { [weak self] _ in
                self?.unpark(key)?.remove()
                self?.dropOverlayIfEmpty()
            }
            RunLoop.main.add(timer, forMode: .common)
            parkTimers[key] = timer
        }
        views.removeAll()
        dropOverlayIfEmpty()
    }

    /// The parked view of `key`, no longer parked (its timer stopped); nil when there is none.
    @discardableResult
    private func unpark(_ key: String) -> ChildView? {
        parkTimers.removeValue(forKey: key)?.invalidate()
        return parked.removeValue(forKey: key)
    }

    private func dropOverlayIfEmpty() {
        guard views.isEmpty, parked.isEmpty else { return }
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// The tab is going: every view, parked ones too.
    func removeAll() {
        for view in views.values { view.remove() }
        views.removeAll()
        for key in Array(parked.keys) { unpark(key)?.remove() }
        dropOverlayIfEmpty()
    }

    /// For the probe: the parked views' keys, and a view by its page id.
    var parkedKeys: [String] { parked.keys.sorted() }
    func view(_ id: String) -> ChildView? { views[id] }
}

/// WebKit-specific mouse notification; placement and clipping live in SDK Views.
final class ChildWebView: WKWebView {
    var pressed: (() -> Void)?
    override func mouseDown(with event: NSEvent) { pressed?(); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { pressed?(); super.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { pressed?(); super.otherMouseDown(with: event) }
}

/// The surface's content: the web view and, over it while the view is discarded or coming
/// back, the picture it last showed. Its subviews fill it. `visibility` is told when it is
/// hidden or shown (by the surface, or by an ancestor: the host concealing the tab) and when
/// it moves to another window.
final class ChildContent: NSView {
    var visibility: (() -> Void)?
    override var isFlipped: Bool { true }
    override func viewDidHide() { super.viewDidHide(); visibility?() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibility?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); visibility?() }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for view in subviews { view.frame = bounds }
    }
}

/// The last picture of a discarded view, scaled to fill; the mouse goes through it to the
/// web view coming back under it.
final class DiscardedPicture: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One view: the WKWebView, its place, and the reports to the page. KVO on the web view's
/// url / title / loading / progress / history, coalesced into one report per run of the loop.
/// A view with a profile has the profile's store; with a proxy, it loads nothing before the
/// store has the proxy (a tunnel's listener has a port), so no connection of it goes direct.
///
/// Discarding (`browser.discard_after`): a view hidden that long (not shown by its last
/// `place`, never placed, parked, in a hidden ancestor — a concealed Tilr tab —, or in a window
/// that is not visible: occluded, minimized, on another Space) drops its WKWebView, so its
/// WebContent process exits. Its picture (`takeSnapshot` shortly after it went hidden, while
/// its process still ran; the last one taken when that fails) and its
/// `interactionState` (the back/forward list, the current entry's scroll) are kept; the picture
/// stays where the view was. A view playing media, capturing, or fullscreen is kept. A
/// `place` that shows it, a navigation, a history op and automation bring it back: a new
/// WKWebView of the same configuration and store gets the `interactionState` (the current entry loads again; script state is gone)
/// under the picture, which goes at its first `didFinish` (or after `automation_timeout`
/// unless the load failed: then it stays, with the error reported).
final class ChildView: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The page's id of the view; a new page's when it adopts the view.
    private(set) var id: String
    /// The page's `key` (stable across its reloads), and the profile the view was made with.
    let key: String?
    let profile: NSDictionary
    /// Waiting for a new page to adopt it: hidden, media suspended, no reports.
    private(set) var parked = false
    /// The web view; nil while the view is discarded.
    private(set) var webView: ChildWebView!
    let automation: BrowserAutomation
    private(set) var surface: ViewSurface!
    private let content = ChildContent()
    private let report: ([String: Any]) -> Void
    private var observers: [NSKeyValueObservation] = []
    private var error: String?
    private var pending = false
    private let lease: Lease
    /// The settings the view was made with: a web view made again (a discarded one coming
    /// back) gets the same configuration.
    private let made: BrowserSettings
    /// A tunnel's last failed handshake (or its listener's failure); nil once one went through.
    private var proxyError: String?
    /// Until the store has the proxy: the URL to load then.
    private var held = true
    private var waiting: String?
    /// The last report sent, and when a report was last sent; a trailing one waiting for
    /// `progressInterval` when only the progress changed.
    private var sent: NSDictionary?
    private var sentAt = Date.distantPast
    private var progressInterval: TimeInterval = 0
    private var progressTimer: Timer?

    /// What a discarded view showed: its history and scroll (`interactionState`) and the state
    /// it reports meanwhile.
    struct Discarded {
        let interaction: Any?
        let url: String
        let title: String
        let canGoBack: Bool
        let canGoForward: Bool
    }
    /// Set while the view has no web view.
    private(set) var discarded: Discarded?
    /// Set while a web view made again loads under the picture: what it came back from.
    private var restoring: Discarded?
    private(set) var picture: DiscardedPicture?
    private var discardAfter: TimeInterval = 0
    private var discardTimer: Timer?
    /// A discard waiting for the media state or the snapshot.
    private var discarding = false
    private var restoreTimeout: TimeInterval
    private var restoreTimer: Timer?
    /// The hidden state last acted on (a picture taken, the view brought back); `place` and
    /// `park` act once they are done, not on the hide they cause.
    private var seenHidden = true
    private var placing = false
    /// The window whose occlusion the view follows.
    private weak var observedWindow: NSWindow?
    private var occlusionObserver: NSObjectProtocol?
    /// Automation waiting for a view coming back.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(id: String, key: String? = nil, profile: NSDictionary = NSDictionary(), settings: BrowserSettings, lease: Lease, parent: NSView, report: @escaping ([String: Any]) -> Void) {
        self.id = id
        self.key = key
        self.profile = profile
        self.report = report
        self.lease = lease
        made = settings
        restoreTimeout = settings.automationTimeout
        automation = BrowserAutomation(timeout: settings.automationTimeout, privateInput: settings.automationPrivateInput, inputInterval: settings.automationInputInterval)
        super.init()
        surface = ViewSurface(content: content, parent: parent)
        webView = makeWebView()
        // While a resize is throttled the view keeps its last size inside the surface: a gap
        // shows the views' under-page color (white, set in makeWebView) rather than whatever
        // is behind the tile.
        surface.layer?.backgroundColor = webView.underPageBackgroundColor.cgColor
        apply(settings)
        content.visibility = { [weak self] in self?.visibilityChanged() }
        observeWindow()
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

    /// A WKWebView of the view's configuration (`made`, the lease's store, the automation
    /// script), observed, in the content under the picture.
    private func makeWebView() -> ChildWebView {
        let configuration = WKWebViewConfiguration()
        automation.reset()
        automation.install(configuration.userContentController, mainFrameOnly: made.automationFrames == "main")
        // The profile's store, or the default one: cookies and logins shared by every view
        // without a profile. Both kept across launches.
        configuration.websiteDataStore = lease.store
        configuration.preferences.isElementFullscreenEnabled = true
        // Unavailable (logged once by WebKitFeatures): the views stay at 60 Hz.
        if made.highRefreshRate { WebKitFeatures.set(WebKitFeatures.near60FPS, enabled: false, on: configuration.preferences) }
        let webView = ChildWebView(frame: content.bounds, configuration: configuration)
        automation.webView = webView
        webView.wantsLayer = true
        webView.pressed = { [weak self] in
            guard let self, !self.parked else { return }
            self.report(["id": self.id, "type": "press"])
        }
        if !made.userAgent.isEmpty { webView.customUserAgent = made.userAgent }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = made.inspectable
        webView.underPageBackgroundColor = .white
        content.addSubview(webView, positioned: .below, relativeTo: picture)
        let changed: (WKWebView, Any) -> Void = { [weak self] _, _ in self?.schedule() }
        observers = [
            webView.observe(\.url, changeHandler: changed),
            webView.observe(\.title, changeHandler: changed),
            webView.observe(\.isLoading, changeHandler: changed),
            webView.observe(\.estimatedProgress, changeHandler: changed),
            webView.observe(\.canGoBack, changeHandler: changed),
            webView.observe(\.canGoForward, changeHandler: changed),
        ]
        return webView
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
        restore()
        webView.load(URLRequest(url: local(url) ?? url))
    }

    /// The page's history ops; a discarded view comes back first (a reload is its coming back).
    func goBack() { restore(); webView.goBack() }
    func goForward() { restore(); webView.goForward() }
    func reload() { if !restore() { webView.reload() } }
    func stopLoading() { webView?.stopLoading() }

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
    /// Shown, a discarded view comes back; hidden, the discard timer starts.
    func place(_ rect: CGRect, visible: Bool, z: Int, holes: [CGRect]) {
        placing = true
        surface.place(rect, visible: visible, z: z, holes: holes)
        placing = false
        visibilityChanged()
    }

    /// The settings a view takes after it is made (a config reload).
    func apply(_ settings: BrowserSettings) {
        surface.resizeInterval = settings.liveResizeInterval / 1000
        progressInterval = settings.progressInterval / 1000
        restoreTimeout = settings.automationTimeout
        if discardAfter != settings.discardAfter {
            discardAfter = settings.discardAfter
            discardTimer?.invalidate()
            discardTimer = nil
            // Turned on while hidden: the picture a discard will show.
            if hidden { schedulePicture() }
            armDiscard()
        }
    }

    /// The page that made it navigated: hidden (WebKit stops rendering it), out of the focus,
    /// media suspended (`setAllMediaPlaybackSuspended`, public, macOS 12), reports held.
    func park() {
        placing = true
        parked = true
        progressTimer?.invalidate()
        progressTimer = nil
        surface.isHidden = true
        placing = false
        if let webView {
            if let window = webView.window, let responder = window.firstResponder as? NSView,
               responder === webView || responder.isDescendant(of: webView) {
                window.makeFirstResponder(nil)
            }
            webView.setAllMediaPlaybackSuspended(true) {}
        }
        visibilityChanged()
    }

    /// Bound to the new page's `id`: in `parent` (the new page's overlay), media resumed, the
    /// whole state reported with `adopted: true`. Shown again by the page's next `place` (a
    /// discarded view comes back then).
    func adopt(id: String, parent: NSView) {
        self.id = id
        parked = false
        if surface.superview !== parent { parent.addSubview(surface) }
        webView?.setAllMediaPlaybackSuspended(false) {}
        let state = self.state
        sent = state as NSDictionary
        sentAt = Date()
        report(state.merging(["adopted": true]) { $1 })
        armDiscard()
    }

    func remove() {
        lease.end()
        content.visibility = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        cancelPicture()
        discardTimer?.invalidate()
        discardTimer = nil
        restoreTimer?.invalidate()
        restoreTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        if let webView { drop(webView) }
        webView = nil
        resumeWaiters()
        surface.removeFromSuperview()
    }

    /// The web view out of use: unobserved, without delegates or the automation's handler,
    /// its media closed and paused, its loading stopped, out of the view tree.
    private func drop(_ webView: ChildWebView) {
        observers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.pressed = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        // Picture in picture, fullscreen video and playing media would outlive the view.
        webView.closeAllMediaPresentations {}
        webView.pauseAllMediaPlayback {}
        webView.stopLoading()
        webView.removeFromSuperview()
        if automation.webView === webView { automation.webView = nil }
    }

    // MARK: Discarding

    /// Not seen: not shown by the last `place` (or never placed), parked, in a hidden ancestor
    /// (a concealed tab), or in a window without `.visible` occlusion state. What the page is
    /// told (`visible` in the list) stays the page's own; only `discarded` follows this.
    private var hidden: Bool {
        parked || !surface.shown || content.isHiddenOrHasHiddenAncestor
            || content.window.map { !$0.occlusionState.contains(.visible) } ?? false
    }

    /// Follows the occlusion of the window the view is in (re-subscribed when it moves).
    private func observeWindow() {
        let window = content.window
        guard window !== observedWindow || (window != nil && occlusionObserver == nil) else { return }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        observedWindow = window
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            self?.visibilityChanged()
        }
    }

    /// The view went hidden or was shown (a `place`, parking, an ancestor, the window's
    /// occlusion): hidden, its picture is taken and the discard timer starts; shown, a
    /// discarded view comes back.
    private func visibilityChanged() {
        guard !placing, content.visibility != nil else { return }
        observeWindow()
        let now = hidden
        if now != seenHidden {
            seenHidden = now
            if now { schedulePicture() } else { cancelPicture() }
        }
        if !now { restore() }
        armDiscard()
    }

    /// Starts the discard timer of a hidden live view, stops it for a shown one.
    private func armDiscard() {
        guard hidden, discardAfter > 0, webView != nil, restoring == nil, !discarding, surface.superview != nil else {
            discardTimer?.invalidate()
            discardTimer = nil
            return
        }
        guard discardTimer == nil else { return }
        let timer = Timer(timeInterval: discardAfter, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.discardTimer = nil
            self.discard()
        }
        RunLoop.main.add(timer, forMode: .common)
        discardTimer = timer
    }

    /// Releases the web content of a view hidden for `discardAfter` (see the class comment);
    /// a view that plays media (a media element of its documents playing: hidden views keep
    /// playing; a parked one's media is suspended and does not count), captures, is fullscreen
    /// or waits for its proxy is kept, and checked again after another `discardAfter`. A page
    /// that does not answer within `automation_timeout` (its process suspended: a page hidden a
    /// while, which plays nothing) counts as not playing.
    /// The media check holds the web view weakly, and its `automation_timeout` fallback is
    /// cancelled once it answers: a released view goes at once.
    func discard() {
        guard let webView, hidden, !discarding else { return }
        guard !held, restoring == nil else { return armDiscard() }
        discarding = true
        var answered = false
        var fallback: DispatchWorkItem?
        let decide: (Bool) -> Void = { [weak self, weak webView] playing in
            guard !answered else { return }
            answered = true
            fallback?.cancel()
            fallback = nil
            guard let self, let webView, self.webView === webView, self.discarding else { return }
            self.discarding = false
            let busy = (playing && !self.parked) || webView.cameraCaptureState != .none
                || webView.microphoneCaptureState != .none || webView.fullscreenState != .notInFullscreen
            guard !busy, self.hidden else { return self.armDiscard() }
            self.release(webView)
        }
        let work = DispatchWorkItem { decide(false) }
        fallback = work
        Task { @MainActor [weak self] in
            guard let automation = self?.automation, self?.parked == false else { return decide(false) }
            decide(await automation.playing())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreTimeout, execute: work)
    }

    /// The view's last picture, taken shortly after it went hidden (`live_resize_interval`
    /// later, so a float dragged over it does not snapshot it on every cover) while its process
    /// still runs: by the time it is discarded the process may be suspended and draw nothing.
    /// `afterScreenUpdates` off: a hidden view gets no rendering update to wait for. A snapshot
    /// that fails (a view hidden by an ancestor may draw none) keeps the one before.
    private var lastPicture: NSImage?
    private var pictureWork: DispatchWorkItem?
    private var pictureTaking = false

    private func schedulePicture() {
        guard discardAfter > 0, webView != nil, pictureWork == nil, !pictureTaking else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pictureWork = nil
            self.takePicture()
        }
        pictureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + surface.resizeInterval, execute: work)
    }

    private func cancelPicture() {
        pictureWork?.cancel()
        pictureWork = nil
    }

    private func takePicture() {
        guard let webView, hidden, !pictureTaking else { return }
        pictureTaking = true
        let snapshot = WKSnapshotConfiguration()
        snapshot.afterScreenUpdates = false
        webView.takeSnapshot(with: snapshot) { [weak self, weak webView] image, _ in
            guard let self else { return }
            self.pictureTaking = false
            guard let image, let webView, self.webView === webView else { return }
            self.lastPicture = image
        }
    }

    private func release(_ webView: ChildWebView) {
        discarded = Discarded(interaction: webView.interactionState, url: webView.url?.absoluteString ?? "",
                              title: webView.title ?? "", canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        progressTimer?.invalidate()
        progressTimer = nil
        drop(webView)
        self.webView = nil
        let picture = self.picture ?? DiscardedPicture(frame: content.bounds)
        picture.imageScaling = .scaleAxesIndependently
        picture.image = lastPicture
        if picture.superview !== content { content.addSubview(picture) }
        self.picture = picture
        cancelPicture()
        print("browser-webkit: \(id) discarded (\(URL(string: discarded?.url ?? "")?.host ?? "no host"))")
        schedule()
    }

    /// A discarded view comes back (see the class comment): false when it was not discarded.
    @discardableResult
    func restore() -> Bool {
        guard let saved = discarded else { return false }
        discarded = nil
        restoring = saved
        discardTimer?.invalidate()
        discardTimer = nil
        let webView = makeWebView()
        self.webView = webView
        if let interaction = saved.interaction { webView.interactionState = interaction }
        if webView.url == nil, !webView.isLoading, let url = URL(string: saved.url), !saved.url.isEmpty {
            webView.load(URLRequest(url: url))
        }
        print("browser-webkit: \(id) restoring (\(URL(string: saved.url)?.host ?? "no host"))")
        let timer = Timer(timeInterval: restoreTimeout, repeats: false) { [weak self] _ in self?.restored(timedOut: true) }
        RunLoop.main.add(timer, forMode: .common)
        restoreTimer = timer
        schedule()
        return true
    }

    /// The view that came back painted (`didFinish`), or the wait for it ran out: the picture
    /// goes, unless the load failed (then it stays until a load finishes); automation waiting
    /// for the view goes on either way.
    private func restored(timedOut: Bool) {
        guard restoring != nil else { return }
        restoreTimer?.invalidate()
        restoreTimer = nil
        if !(timedOut && error != nil) {
            restoring = nil
            picture?.removeFromSuperview()
            picture = nil
        }
        resumeWaiters()
        schedule()
        // Back while still hidden (automation, a navigation, a history op): a new picture for
        // the next discard (the last one stays if it fails).
        if hidden { schedulePicture() }
        armDiscard()
    }

    /// For automation: a discarded view comes back and has loaded (or the wait ran out).
    func wake() async {
        restore()
        guard restoreTimer != nil, webView != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    // MARK: Reports

    private func schedule() {
        guard !pending, !parked else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.send()
        }
    }

    /// Sends the state unless it is the last one sent; a change of `progress` alone (the load
    /// still going) waits until `progressInterval` has passed since the last report.
    private func send() {
        guard !parked else { return }
        let state = self.state as NSDictionary
        if let sent, sent.isEqual(state) { return }
        let progressOnly: Bool = {
            guard let sent, let webView, webView.isLoading, webView.estimatedProgress < 1 else { return false }
            let other = state.mutableCopy() as! NSMutableDictionary
            other["progress"] = sent["progress"]
            return sent.isEqual(other)
        }()
        let wait = progressOnly ? sentAt.addingTimeInterval(progressInterval).timeIntervalSinceNow : 0
        guard wait <= 0 else {
            guard progressTimer == nil else { return }
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.progressTimer = nil
                self.send()
            }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
            return
        }
        progressTimer?.invalidate()
        progressTimer = nil
        sent = state
        sentAt = Date()
        report(state as! [String: Any])
    }

    var state: [String: Any] {
        let saved = discarded ?? restoring
        let live = webView?.title ?? ""
        var state: [String: Any] = [
            "id": id,
            "url": webView?.url?.absoluteString ?? saved?.url ?? "",
            // A view coming back has no title until its page has one: the one it had.
            "title": webView == nil ? saved?.title ?? "" : live.isEmpty ? restoring?.title ?? "" : live,
            "loading": webView?.isLoading ?? false,
            "progress": webView?.estimatedProgress ?? 1,
            "canGoBack": webView?.canGoBack ?? saved?.canGoBack ?? false,
            "canGoForward": webView?.canGoForward ?? saved?.canGoForward ?? false,
            "error": error ?? NSNull(),
            "discarded": discarded != nil,
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

    /// A view coming back has painted its page: the picture goes.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if restoring != nil { restored(timedOut: false) }
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
        if !parked, let url = navigationAction.request.url?.absoluteString, !url.isEmpty, url != "about:blank" {
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
