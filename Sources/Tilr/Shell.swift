import AppKit
import WebKit

// Private SkyLight calls. AppKit has no public API to read or choose a window's Space.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: Int32, _ windows: CFArray, _ space: UInt64)

enum Spaces {
    static let cid = CGSMainConnectionID()

    /// Desktop Spaces (type 0, i.e. not fullscreen ones) per display, in Mission Control order.
    static func desktopsByDisplay() -> [[UInt64]] {
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        return displays.map { display in
            (display["Spaces"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? Int) == 0 }
                .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
    }

    static func active() -> UInt64 { CGSGetActiveSpace(cid) }

    static func of(_ window: NSWindow) -> [UInt64] {
        let ids = CGSCopySpacesForWindows(cid, 7, [window.windowNumber] as CFArray) as? [NSNumber] ?? []
        return ids.map(\.uint64Value)
    }

    static func move(_ window: NSWindow, to space: UInt64) {
        CGSMoveWindowsToManagedSpace(cid, [window.windowNumber] as CFArray, space)
    }
}

enum Mode {
    /// Covers the whole screen in the current Space, Dock and menu bar hidden.
    case fullscreen
    /// A normal window with a title bar.
    case window
    /// A window without a title bar; dragged by its top 32px (the page's header bar).
    case frameless
}

/// Borderless windows refuse key status by default, which would leave the app without keyboard input.
final class Window: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One app: a window whose whole content is a web view showing the app's folder as
/// `tilr://<name>/` (see Site), or the dev server. Owns the window's mode, its Space settings and
/// the folder watcher. The AppDelegate keeps the list of shells and the menu; every shell gets
/// the same commands, applied to the one whose window is key.
final class Shell: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private(set) var app: Site.App
    let window = Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    let site: SiteSchemeHandler
    let webView: WKWebView
    var watcher: FolderWatcher?
    var mode = Mode.fullscreen
    var pending: Mode?
    var allSpaces = false
    var onTop = false
    private var dragMonitor: Any?

    /// A page finished loading.
    var didLoad: ((Shell) -> Void)?
    /// The window became key or a toggle flipped; the menu mirrors both.
    var changed: ((Shell) -> Void)?
    /// The window closed; the owner drops the shell.
    var closed: ((Shell) -> Void)?

    init(app: Site.App) {
        self.app = app
        site = SiteSchemeHandler(root: app.root)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(site, forURLScheme: SiteSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        window.title = app.name
        window.delegate = self
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.isInspectable = true  // Safari → Develop → Tilr
        window.contentView = webView
        installDrag()
    }

    /// Shows the window in fullscreen mode and loads the page.
    func open() {
        set(.fullscreen)
        show(app)
    }

    // MARK: Web content

    /// The dev server, the site, or the placeholder while the folder has no `index.html`.
    var pageURL: URL {
        Site.devURL ?? (Site.hasIndex(app.root) ? app.origin : Site.placeholder(for: app.root))
    }

    /// Points the web view at the app's folder (or the dev server) and watches it. Called at
    /// launch and whenever the config moves the app to another folder.
    func show(_ app: Site.App) {
        self.app = app
        site.root = app.root
        window.title = app.name
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
        window.makeFirstResponder(webView)
        didLoad?(self)
    }

    // MARK: Window modes

    /// Dock and menu bar hidden only while a fullscreen-mode window is key. App-wide, so the key
    /// window's shell applies it (windowDidBecomeKey).
    var presentationOptions: NSApplication.PresentationOptions {
        mode == .fullscreen ? [.hideDock, .hideMenuBar] : []
    }

    func set(_ new: Mode) {
        // Leaving native fullscreen (the green button) is animated; the switch finishes in
        // windowDidExitFullScreen.
        if window.styleMask.contains(.fullScreen) {
            pending = new
            window.toggleFullScreen(nil)
            return
        }
        mode = new
        applyCollectionBehavior()
        let screen = window.screen ?? NSScreen.main!
        let windowFrame = screen.visibleFrame.insetBy(dx: 200, dy: 150)
        switch new {
        case .fullscreen:
            // Same Space as before, no animation: the window just covers the whole screen
            // and the app hides the Dock and the menu bar while it is active.
            window.styleMask = .borderless
            window.setFrame(screen.frame, display: true)
        case .window:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setFrame(windowFrame, display: true)
        case .frameless:
            window.styleMask = [.borderless, .resizable]
            window.setFrame(windowFrame, display: true)
        }
        NSApp.presentationOptions = presentationOptions
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    /// Frameless mode has no title bar to grab, so a drag that starts in the top 32px moves
    /// the window. The events still reach the page, so the header's clock stays clickable.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    private func installDrag() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self, mode == .frameless, event.window === window else { return event }
            if event.type == .leftMouseDown {
                let fromTop = window.frame.height - event.locationInWindow.y
                dragStart = fromTop <= 32 ? (NSEvent.mouseLocation, window.frame.origin) : nil
            } else if let start = dragStart {
                let mouse = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                              y: start.origin.y + mouse.y - start.mouse.y))
            }
            return event
        }
    }

    func applyCollectionBehavior() {
        var behavior: NSWindow.CollectionBehavior = [.fullScreenPrimary]
        if allSpaces { behavior.insert(.canJoinAllSpaces) }
        window.collectionBehavior = behavior
    }

    /// Above every other app's windows, floating panels included; stays on when the mode changes.
    func toggleOnTop() {
        onTop.toggle()
        window.level = onTop ? .screenSaver : .normal
        print("\(app.name) always on top:", onTop)
        changed?(self)
    }

    func toggleAllSpaces() {
        allSpaces.toggle()
        applyCollectionBehavior()
        print("\(app.name) show on all desktops:", allSpaces)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.presentationOptions = presentationOptions
        changed?(self)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let next = pending {
            pending = nil
            set(next)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        watcher = nil
        closed?(self)
    }

    // MARK: Spaces

    /// Desktop Spaces of the display the window is on, and the window's index among them.
    func desktops() -> (all: [UInt64], index: Int?) {
        let current = Spaces.of(window).first
        let all = Spaces.desktopsByDisplay().first { list in current.map(list.contains) ?? false }
            ?? Spaces.desktopsByDisplay().first ?? []
        return (all, current.flatMap(all.firstIndex(of:)))
    }

    func moveToNextSpace() {
        let (all, index) = desktops()
        guard let index, all.count > 1 else {
            // In native fullscreen the window is a Space of its own and is not on any desktop.
            print("move to next desktop: skipped (window is not on a desktop, or there is only one)")
            return
        }
        let target = (index + 1) % all.count
        Spaces.move(window, to: all[target])
        // The window server applies the move asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            let moved = Spaces.of(window) == [all[target]]
            print("move to desktop \(target + 1):", moved ? "ok" : "FAILED")
        }
    }
}
