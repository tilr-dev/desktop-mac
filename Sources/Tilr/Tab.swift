import AppKit
import WebKit

/// One app inside the shell's window: a web view showing the app's folder as `tilr://<name>/`
/// (see Site), or the dev server, plus the folder watcher that reloads it. The Shell keeps the
/// tabs and shows one at a time; there is no tab bar, switching is by shortcut.
final class Tab: NSObject, WKNavigationDelegate {
    private(set) var app: Site.App
    let site: SiteSchemeHandler
    private(set) var webView: WKWebView
    /// Separately installed native providers, scoped to this app/tab.
    var nativePlugins: NativePluginSession!
    /// The page's connections to the user's SSH agent (Agent.swift): gone with the page.
    let agent: AgentHost
    private let localServer = LocalServerBridge()
    var watcher: FolderWatcher?

    /// A page finished loading.
    var didLoad: ((Tab) -> Void)?

    struct ConsoleEntry {
        /// Seconds since 1970.
        let time: Double
        /// log, info, warn, error, debug, pageerror.
        let type: String
        let text: String
    }

    /// The page's console, oldest first, the last `consoleLimit` entries (Tilr Control's `console`).
    var console: [ConsoleEntry] = []
    private let consoleLimit: Int
    private let relay = ConsoleRelay()
    private let catchesConsole: Bool

    /// The page has finished loading and no navigation is under way: JavaScript may be
    /// evaluated (during a navigation it can hang the call). Debug mode's `status` and `record`
    /// read it.
    private(set) var isLoaded = false

    /// `control`: with Tilr Control on, the page's console is caught for it. `browser`: how the
    /// page's web views are made. `collector`: debug mode's script (Debug.swift), nil while off.
    init(app: Site.App, control: Config.Control?, browser: Config.Browser, native: Config.NativePlugins, sshAgent: Config.SSHAgent, collector: String? = nil) {
        self.app = app
        consoleLimit = control?.console ?? 0
        catchesConsole = control != nil
        site = SiteSchemeHandler(root: app.root)
        agent = AgentHost(settings: sshAgent)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Instance.store
        configuration.setURLSchemeHandler(site, forURLScheme: SiteSchemeHandler.scheme)
        let controller = configuration.userContentController
        if control != nil {
            controller.addUserScript(WKUserScript(source: ConsoleRelay.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            controller.add(relay, name: ConsoleRelay.name)
        }
        if let collector { controller.addUserScript(PerfCollector.userScript(collector)) }
        controller.add(agent, name: AgentHost.name)
        controller.addScriptMessageHandler(localServer, contentWorld: .page, name: LocalServerBridge.name)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        relay.tab = self
        localServer.tab = self
        nativePlugins = NativePluginSession(tab: self, settings: native, browser: browser)
        nativePlugins.attach(to: controller)
        agent.send = { [weak self] in self?.send(event: AgentHost.event, detail: $0) }
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.isInspectable = true  // Safari → Develop → Tilr
        webView.autoresizingMask = [.width, .height]
    }

    /// The dev server, the site, or the placeholder while the folder has no `index.html`.
    var pageURL: URL {
        Site.devURL ?? (Site.hasIndex(app.root) ? app.origin : Site.placeholder(for: app.root))
    }

    /// Points the web view at the app's folder (or the dev server) and watches it. Called at
    /// launch and whenever the config moves the app to another folder.
    func show(_ app: Site.App) {
        let moved = self.app != app
        self.app = app
        site.root = app.root
        if moved { resetWebView() }
        if Site.devURL == nil {
            // The folder must exist for FSEvents to follow it; an index.html put there later is picked up.
            watcher = nil
            do {
                try Site.prepareDirectory(app.root)
                // An edit reloads the page or a plugin; a dev server has its own live reload.
                watcher = FolderWatcher(app.root) { [weak self] in self?.siteChanged($0) }
            } catch {
                print("site: cannot create folder \(app.root.path): \(error)")
            }
        }
        print("\(app.name):", pageURL.absoluteString, Site.devURL == nil ? "← \(app.root.path)" : "")
        reload()
    }

    func reload() {
        isLoaded = false
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

    /// Debug mode switched: the user scripts again, with or without the collector, and a reload
    /// (a user script applies to the next navigation).
    func setCollector(_ source: String?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if catchesConsole {
            controller.addUserScript(WKUserScript(source: ConsoleRelay.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let source { controller.addUserScript(PerfCollector.userScript(source)) }
        reload()
    }

    func log(type: String, text: String) {
        console.append(ConsoleEntry(time: Date().timeIntervalSince1970, type: type, text: text))
        if console.count > consoleLimit { console.removeFirst(console.count - consoleLimit) }
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
        guard let data = try? JSONSerialization.data(withJSONObject: detail), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent(\(Self.literal(event)), { detail: \(json) }))") { _, error in
            if let error { print("\(self.app.name) \(event):", error.localizedDescription) }
        }
    }

    /// A JS string literal.
    static func literal(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
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
        nativePlugins.pageDidNavigate()
        agent.closeAll()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoaded = !webView.isLoading
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoaded = !webView.isLoading && webView.url != nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        // The key tab takes the keyboard once it has a page; a hidden one must not steal it.
        if !webView.isHidden { webView.window?.makeFirstResponder(webView) }
        didLoad?(self)
    }
}
