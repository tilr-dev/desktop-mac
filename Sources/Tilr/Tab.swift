import AppKit
import WebKit

/// One app inside the shell's window: a web view showing the app's folder as `tilr://<name>/`
/// (see Site), or the dev server, plus the folder watcher that reloads it. The Shell keeps the
/// tabs and shows one at a time; there is no tab bar, switching is by shortcut.
final class Tab: NSObject, WKNavigationDelegate {
    private(set) var app: Site.App
    let site: SiteSchemeHandler
    let webView: WKWebView
    var watcher: FolderWatcher?

    /// A page finished loading.
    var didLoad: ((Tab) -> Void)?

    init(app: Site.App) {
        self.app = app
        site = SiteSchemeHandler(root: app.root)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(site, forURLScheme: SiteSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
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
        self.app = app
        site.root = app.root
        if Site.devURL == nil {
            // The folder must exist for FSEvents to follow it; an index.html put there later is picked up.
            try? FileManager.default.createDirectory(at: app.root, withIntermediateDirectories: true)
            // An edit in the folder reloads the page or a plugin; a dev server has its own live reload.
            watcher = FolderWatcher(app.root) { [weak self] in self?.siteChanged($0) }
        }
        print("\(app.name):", pageURL.absoluteString, Site.devURL == nil ? "← \(app.root.path)" : "")
        reload()
    }

    func reload() {
        webView.load(URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData))
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The key tab takes the keyboard once it has a page; a hidden one must not steal it.
        if !webView.isHidden { webView.window?.makeFirstResponder(webView) }
        didLoad?(self)
    }
}
