import AppKit
import WebKit

/// One app inside the shell's window: a web view showing the app's folder as `tilr://<name>/`
/// (see Site), or the dev server, plus the folder watcher that reloads it. The Shell keeps the
/// tabs and shows one at a time; there is no tab bar, switching is by shortcut.
final class Tab: NSObject, WKNavigationDelegate {
    private(set) var app: Site.App
    let site: SiteSchemeHandler
    private(set) var webView: WKWebView
    /// What the Shell stacks, shows, hides and slides: a plain layer-backed view the web view
    /// fills. A slide moves this view's layer, never a view frame, so WebKit sees no geometry
    /// change (no per-frame view-frame update to the WebContent process).
    let container = NSView()
    /// Separately installed native providers, scoped to this app/tab.
    var nativePlugins: NativePluginSession!
    /// The page's connections to the user's SSH agent (Agent.swift): gone with the page.
    let agent: AgentHost
    private let localServer = LocalServerBridge()
    private let performanceBridge = PerformanceBridge()
    var watcher: FolderWatcher?
    /// `watch.latency`: seconds FSEvents gathers the folder's changes.
    private let watchLatency: Double
    /// The page has been asked to load (`loadIfNeeded`): until then the web view is blank,
    /// the folder unwatched and the native providers not started (`switch.preload`).
    private(set) var started = false

    /// A page finished loading.
    var didLoad: ((Tab) -> Void)?
    /// A page failed to load (`didFail`, `didFailProvisionalNavigation`).
    var didFailLoad: ((Tab) -> Void)?

    struct ConsoleEntry {
        /// Seconds since 1970.
        let time: Double
        /// log, info, warn, error, debug, pageerror.
        let type: String
        let text: String
    }

    /// The page's console, the last `control.console` entries (Tilr Control's `console`).
    var console: ConsoleLog
    private let relay = ConsoleRelay()

    /// The page has finished loading and no navigation is under way: JavaScript may be
    /// evaluated (during a navigation it can hang the call). Debug mode's `status` and `record`
    /// read it.
    private(set) var isLoaded = false {
        didSet { if isLoaded { wake() } }
    }
    /// The last navigation has ended, loaded or failed: a `firstLoad` caller has nothing left
    /// to wait for. Cleared when a navigation starts.
    private(set) var loadEnded = false {
        didSet { if loadEnded { wake() } }
    }
    /// `firstLoad` callers, resumed when the load ends (loaded or failed) or their time is up.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Returns when the page has loaded, its load has failed, or after `timeout` seconds,
    /// whichever comes first.
    @MainActor
    func firstLoad(within timeout: Double) async {
        guard !isLoaded, !loadEnded else { return }
        let id = UUID()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            waiters[id] = done
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func wake() {
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    /// `control`: with Tilr Control on, the page's console is caught for it (`control.console_capture`).
    /// `browser`: how the page's web views are made. `inspectable`: `debug.inspectable`.
    /// `collector`: debug mode's script (Debug.swift), nil while off.
    init(app: Site.App, control: Config.Control?, browser: Config.Browser, native: Config.NativePlugins, sshAgent: Config.SSHAgent,
         watchLatency: Double, inspectable: Bool, collector: String? = nil) {
        self.app = app
        self.watchLatency = watchLatency
        let catchesConsole = control?.consoleCapture == true
        console = ConsoleLog(capacity: catchesConsole ? control?.console ?? 0 : 0)
        site = SiteSchemeHandler(root: app.root)
        agent = AgentHost(settings: sshAgent)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Instance.store
        configuration.setURLSchemeHandler(site, forURLScheme: SiteSchemeHandler.scheme)
        let controller = configuration.userContentController
        if catchesConsole, let control {
            controller.addUserScript(WKUserScript(source: ConsoleRelay.script(entryMax: control.consoleEntryMax),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: false))
            controller.add(relay, name: ConsoleRelay.name)
        }
        if let collector { controller.addUserScript(WKUserScript(source: collector, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        controller.add(agent, name: AgentHost.name)
        controller.addScriptMessageHandler(localServer, contentWorld: .page, name: LocalServerBridge.name)
        controller.addScriptMessageHandler(performanceBridge, contentWorld: .page, name: PerformanceBridge.name)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        relay.tab = self
        localServer.tab = self
        performanceBridge.tab = self
        nativePlugins = NativePluginSession(tab: self, settings: native, browser: browser)
        nativePlugins.attach(to: controller)
        agent.send = { [weak self] in self?.send(event: AgentHost.event, detail: $0) }
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.isInspectable = inspectable  // Safari → Develop → Tilr
        // The web view fills its container; the Shell sizes the container (a hidden one does not
        // follow the window) and turns its resizing on when it shows the tab.
        container.wantsLayer = true
        container.isHidden = true
        container.autoresizingMask = []
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    /// The dev server, the site, or the placeholder while the folder has no `index.html`.
    var pageURL: URL {
        Site.devURL ?? (Site.hasIndex(app.root) ? app.origin : Site.placeholder(for: app.root))
    }

    /// Points the tab at the app's folder (or the dev server). Whenever the config moves the
    /// app to another folder; a tab that has loaded follows at once, one that has not yet
    /// picks it up on `loadIfNeeded`.
    func show(_ app: Site.App) {
        let moved = self.app != app
        self.app = app
        site.root = app.root
        guard started else { return }
        if moved { resetWebView() }
        load()
    }

    /// Loads the page the first time: starts the native providers, watches the folder and
    /// navigates. The tab being selected, `switch.preload`, or a control command needs the page.
    func loadIfNeeded() {
        guard !started else { return }
        started = true
        nativePlugins.start()
        load()
    }

    /// Watches the folder and loads the page.
    private func load() {
        if Site.devURL == nil {
            // The folder must exist for FSEvents to follow it; an index.html put there later is picked up.
            watcher = nil
            do {
                try Site.prepareDirectory(app.root)
                // An edit reloads the page or a plugin; a dev server has its own live reload.
                watcher = FolderWatcher(app.root, latency: watchLatency) { [weak self] in self?.siteChanged($0) }
            } catch {
                print("site: cannot create folder \(app.root.path): \(error)")
            }
        }
        print("\(app.name):", pageURL.absoluteString, Site.devURL == nil ? "← \(app.root.path)" : "")
        navigate()
    }

    /// Reloads the page; a tab that has not loaded yet loads it.
    func reload() {
        guard started else { return loadIfNeeded() }
        navigate()
    }

    private func navigate() {
        isLoaded = false
        loadEnded = false
        let url = pageURL
        if webView.url == url {
            webView.reloadFromOrigin()
        } else {
            // Crossing between the placeholder and the app starts a fresh history.
            if webView.url != nil || webView.isLoading { resetWebView() }
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    /// WKWebView has no public history-clear API. Keep the configuration (data store,
    /// scripts and bridges), but replace the view when the app itself changes.
    private func resetWebView() {
        let old = webView
        old.navigationDelegate = nil
        old.stopLoading()
        nativePlugins.pageDidNavigate()
        agent.closeAll()
        performanceBridge.reset()
        isLoaded = false
        let next = WKWebView(frame: old.frame, configuration: old.configuration)
        next.navigationDelegate = self
        next.underPageBackgroundColor = old.underPageBackgroundColor
        next.isInspectable = old.isInspectable
        next.autoresizingMask = old.autoresizingMask
        next.isHidden = old.isHidden
        webView = next
        old.superview?.replaceSubview(old, with: next)
    }

    func log(type: String, text: String, time: Double = Date().timeIntervalSince1970) {
        console.append(ConsoleEntry(time: time, type: type, text: text))
    }

    /// A change under `plugins/` goes to the page, which swaps just those plugins in place
    /// (runtime.js). Anything else, or a page without that entry point, reloads the whole page.
    func siteChanged(_ paths: [String]) {
        let root = app.root.resolvingSymlinksInPath().path + "/"
        let changed = paths.compactMap { path -> String? in
            let full = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard full.hasPrefix(root) else { return nil }
            let relative = String(full.dropFirst(root.count))
            // Editors' temporary files and .DS_Store are noise.
            return relative.split(separator: "/").contains { $0.hasPrefix(".") } ? nil : relative
        }
        guard !changed.isEmpty else { return }
        // The placeholder is on screen, or index.html itself changed: it may have appeared or
        // gone, so pick the page again.
        if webView.url?.scheme != SiteSchemeHandler.scheme || changed.contains("index.html") {
            print("\(app.name): reload", changed)
            reload()
            return
        }
        let hot = changed.allSatisfy { $0.hasPrefix("plugins/") || $0 == "plugins.json" }
        guard hot else {
            print("\(app.name): reload", changed)
            webView.reloadFromOrigin()
            return
        }
        webView.callAsyncJavaScript(
            "return window.tilr?.hmr ? await window.tilr.hmr.changed(paths) : null",
            arguments: ["paths": changed], in: nil, in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                if let note = value as? String {
                    print("\(app.name) hmr:", note)
                } else {
                    print("\(app.name): reload", changed, "(page has no hot reload)")
                    webView.reloadFromOrigin()
                }
            case .failure(let error):
                print("\(app.name) hmr: failed:", error.localizedDescription)
                webView.reloadFromOrigin()
            }
        }
    }

    /// Dispatches a CustomEvent on the page's `window` (what the web views report through).
    func send(event: String, detail: [String: Any]) {
        guard started, let json = Self.json(detail) else { return }
        webView.callAsyncJavaScript(Self.dispatch, arguments: ["name": event, "detail": json], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result, let self { print("\(app.name) \(event):", error.localizedDescription) }
        }
    }

    /// The one body every native → page event runs (`send`; `NativePluginSession.emit` adds an
    /// origin check): a constant source JavaScriptCore parses once. `detail` comes as JSON text,
    /// so the page gets exactly what `JSONSerialization` wrote before.
    static let dispatch = "window.dispatchEvent(new CustomEvent(name, { detail: JSON.parse(detail) }))"

    /// `detail` as JSON text, nil when it is not JSON.
    static func json(_ detail: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(detail), let data = try? JSONSerialization.data(withJSONObject: detail) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `tilr://<host>/<path>` → the file under the folder of the app with that host (this tab's
    /// app first, then the others), for what cannot load the scheme itself (AVPlayer).
    func siteFile(_ url: URL) -> URL? {
        guard url.scheme == SiteSchemeHandler.scheme, let host = url.host else { return nil }
        let others = (NSApp.delegate as? AppDelegate)?.tabs.map(\.app) ?? []
        guard let owner = ([app] + others).first(where: { $0.host == host }) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        let root = owner.root.resolvingSymlinksInPath().standardizedFileURL
        let file = parts.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else { return nil }
        return file
    }

    /// The page is leaving (a reload, another URL): its web views have no page to follow, its
    /// agent connections no page to report to. The native audio session stays.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoaded = false
        loadEnded = false
        nativePlugins.pageDidNavigate()
        agent.closeAll()
        performanceBridge.reset()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoaded = !webView.isLoading
        loadFailed()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoaded = !webView.isLoading && webView.url != nil
        loadFailed()
    }

    /// A navigation failed: unless another one is already under way, the load has ended.
    private func loadFailed() {
        guard !webView.isLoading else { return }
        loadEnded = true
        didFailLoad?(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        loadEnded = true
        // The key tab takes the keyboard once it has a page; a hidden one must not steal it.
        if !webView.isHiddenOrHasHiddenAncestor { webView.window?.makeFirstResponder(webView) }
        didLoad?(self)
    }
}
