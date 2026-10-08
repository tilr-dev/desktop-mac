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

/// The whole UI is one web view. Like the iPad app, it shows a local folder served as
/// `tilr://app/` (see Site), unless a dev server is given with `--url` or TILR_URL.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    let window = Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(SiteSchemeHandler(root: Site.root), forURLScheme: SiteSchemeHandler.scheme)
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    let pageURL = Site.devURL ?? SiteSchemeHandler.origin
    var watcher: FolderWatcher?
    var configWatcher: FolderWatcher?
    var config: Config?
    let palette = Palette()
    var mode = Mode.fullscreen
    var pending: Mode?
    var allSpaces = false
    var onTop = false
    let probing = CommandLine.arguments.contains("--probe")
    var probed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadConfig()
        configWatcher = FolderWatcher(Config.dir) { [weak self] _ in self?.reloadConfig() }
        palette.run = { [weak self] in self?.perform($0.action) }
        palette.isOn = { [weak self] in $0.action == .alwaysOnTop && self?.onTop == true }
        installDrag()
        window.delegate = self
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        webView.isInspectable = true  // Safari → Develop → Tilr
        window.contentView = webView

        set(.fullscreen)
        NSApp.activate(ignoringOtherApps: true)
        print("page:", pageURL.absoluteString, Site.devURL == nil ? "← \(Site.root.path)" : "")
        if Site.devURL == nil {
            Site.seed()
            // An edit in the folder reloads the page or a plugin; a dev server has its own live reload.
            watcher = FolderWatcher(Site.root) { [weak self] in self?.siteChanged($0) }
        }
        reload()
    }

    // MARK: Web content

    @objc func reload() {
        webView.load(URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    /// A change under `plugins/` goes to the page, which swaps just those plugins in place
    /// (runtime.js). Anything else, or a page without that entry point, reloads the whole page.
    func siteChanged(_ paths: [String]) {
        let root = Site.root.resolvingSymlinksInPath().path + "/"
        let changed = paths.compactMap { path -> String? in
            let full = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard full.hasPrefix(root) else { return nil }
            let relative = String(full.dropFirst(root.count))
            // Editors' temporary files and .DS_Store are noise.
            return relative.split(separator: "/").contains { $0.hasPrefix(".") } ? nil : relative
        }
        guard !changed.isEmpty else { return }
        let hot = changed.allSatisfy { $0.hasPrefix("plugins/") || $0 == "plugins.json" }
        guard hot else {
            print("site: reload", changed)
            webView.reloadFromOrigin()
            return
        }
        webView.callAsyncJavaScript(
            "return window.tilr?.hmr ? await window.tilr.hmr.changed(paths) : null",
            arguments: ["paths": changed], in: nil, in: .page
        ) { [weak self] result in
            switch result {
            case .success(let value):
                if let note = value as? String {
                    print("hmr:", note)
                } else {
                    print("site: reload", changed, "(page has no hot reload)")
                    self?.webView.reloadFromOrigin()
                }
            case .failure(let error):
                print("hmr: failed:", error.localizedDescription)
                self?.webView.reloadFromOrigin()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.makeFirstResponder(webView)
        if probing && !probed {
            probed = true
            Task { @MainActor in
                await probeWeb()
                probePalette()
                probeSpaces()
            }
        }
    }

    // MARK: Window modes

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
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            window.setFrame(screen.frame, display: true)
        case .window:
            NSApp.presentationOptions = []
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setFrame(windowFrame, display: true)
        case .frameless:
            NSApp.presentationOptions = []
            window.styleMask = [.borderless, .resizable]
            window.setFrame(windowFrame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    /// Frameless mode has no title bar to grab, so a drag that starts in the top 32px moves
    /// the window. The events still reach the page, so the header's clock stays clickable.
    var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func installDrag() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
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

    func windowDidExitFullScreen(_ notification: Notification) {
        if let next = pending {
            pending = nil
            set(next)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Config and commands

    func reloadConfig() {
        guard let loaded = Config.load() else { return }
        config = loaded
        palette.commands = loaded.controlPlane.commands
        buildMenu()
        print("config:", loaded.controlPlane.commands.map(\.title))
    }

    func perform(_ action: Action) {
        switch action {
        case .quit: NSApp.terminate(nil)
        case .fullscreen: set(.fullscreen)
        case .window: set(.window)
        case .frameless: set(.frameless)
        case .alwaysOnTop: toggleOnTop()
        case .reload: reload()
        case .allDesktops: toggleAllSpaces()
        case .nextDesktop: moveToNextSpace()
        }
    }

    /// Above every other app's windows, floating panels included; stays on when the mode changes.
    @objc func toggleOnTop() {
        onTop.toggle()
        window.level = onTop ? .screenSaver : .normal
        buildMenu()
        print("always on top:", onTop)
    }

    @objc func openPalette() {
        palette.isOpen ? palette.close() : palette.open(over: window)
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? Config.Command { perform(command.action) }
    }

    // MARK: Menu

    /// Shortcuts live in the main menu rather than in a key monitor, so every plain key reaches
    /// the terminal. The Edit menu is what makes ⌘C / ⌘V work inside the web view. The
    /// Commands menu mirrors the config's control plane, with each command's key.
    func buildMenu() {
        let main = NSMenu()
        func item(
            _ title: String, _ action: Selector, _ key: String,
            _ modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let parent = NSMenuItem()
            parent.submenu = menu
            main.addItem(parent)
        }
        let plane = config?.controlPlane
        let hotkey = plane?.hotkey
        let commands = (plane?.commands ?? []).map { command in
            let entry = item(command.title, #selector(runCommand(_:)), command.key?.key ?? "", command.key?.modifiers ?? [])
            entry.representedObject = command
            if command.action == .alwaysOnTop { entry.state = onTop ? .on : .off }
            return entry
        }
        submenu("Tilr", [item("Quit Tilr", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Commands", [
            item("Control Plane", #selector(openPalette), hotkey?.key ?? "p", hotkey?.modifiers ?? [.command, .shift]),
            .separator(),
        ] + commands)
        submenu("View", [
            item("Reload", #selector(reload), "r"),
            .separator(),
            item("Show on All Desktops", #selector(toggleAllSpaces), "a", [.command, .shift]),
            item("Move to Next Desktop", #selector(moveToNextSpace), "s", [.command, .shift]),
        ])
        NSApp.mainMenu = main
    }

    @objc func toggleAllSpaces() {
        allSpaces.toggle()
        applyCollectionBehavior()
        print("show on all desktops:", allSpaces)
    }

    // MARK: Spaces

    /// Desktop Spaces of the display the window is on, and the window's index among them.
    func desktops() -> (all: [UInt64], index: Int?) {
        let current = Spaces.of(window).first
        let all = Spaces.desktopsByDisplay().first { list in current.map(list.contains) ?? false }
            ?? Spaces.desktopsByDisplay().first ?? []
        return (all, current.flatMap(all.firstIndex(of:)))
    }

    @objc func moveToNextSpace() {
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

    // MARK: Probe

    /// `--probe`, web part: reports what loaded, clicks through the header's clock menu from JS and,
    /// with `--snapshot PATH`, saves pictures of the top corners of the page.
    @MainActor
    func probeWeb() async {
        let args = CommandLine.arguments
        let path = args.firstIndex(of: "--snapshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        func js(_ source: String) async -> String {
            (try? await webView.evaluateJavaScript(source) as? String) ?? "js error"
        }
        func snapshot(_ name: String) async {
            guard let path else { return }
            for (side, x) in [("left", 0), ("right", webView.bounds.width - 300)] {
                let config = WKSnapshotConfiguration()
                config.rect = NSRect(x: x, y: 0, width: 300, height: 180)
                guard let image = try? await webView.takeSnapshot(configuration: config),
                      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
                else { continue }
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(path)-\(name)-\(side).png"))
            }
        }
        // Lets fonts and layout settle before measuring.
        try? await Task.sleep(nanoseconds: 700_000_000)
        print("page:", webView.url?.absoluteString ?? "none")
        let root = "document.querySelector('tilr-header')?.shadowRoot"
        print("header:", await js("""
            (() => { const r = \(root); if (!r) return 'MISSING';
              const box = r.querySelector('.bar').getBoundingClientRect();
              return JSON.stringify({ logo: r.querySelector('.logo').textContent, clock: r.querySelector('.clock').textContent,
                height: box.height, width: box.width, bodyTop: document.body.getBoundingClientRect().top }); })()
            """))
        print("clock click:", await js("""
            (() => { const r = \(root); r.querySelector('.clock').click();
              return JSON.stringify({ open: !r.querySelector('.menu').hidden,
                rows: [...r.querySelectorAll('.row')].map(row => row.textContent) }); })()
            """))
        await snapshot("menu")
        print("row click:", await js("""
            (() => { const r = \(root); const before = localStorage.getItem('tilr-clock-zone');
              r.querySelectorAll('.row')[1].click();
              const result = JSON.stringify({ clock: r.querySelector('.clock').textContent, open: !r.querySelector('.menu').hidden });
              before === null ? localStorage.removeItem('tilr-clock-zone') : localStorage.setItem('tilr-clock-zone', before);
              return result; })()
            """))
    }

    /// `--probe`, palette part: opens it, filters, closes. Nothing is run.
    func probePalette() {
        palette.open(over: window)
        print("palette:", palette.shown.map(\.title), "open:", palette.isOpen)
        palette.type("win")
        print("palette \"win\":", palette.shown.map(\.title))
        palette.close()
        print("palette closed:", !palette.isOpen)
    }

    /// `--probe`, window part: reports the fullscreen frame and whether a Space move sticks, then quits.
    func probeSpaces() {
        func after(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
        }
        let (all, index) = desktops()
        print("screen frame:", (window.screen ?? NSScreen.main!).frame)
        print("window frame:", window.frame)
        print("presentation options:", NSApp.currentSystemPresentationOptions.rawValue)
        print("desktops:", all, "window on index:", index.map(String.init) ?? "nil")
        guard let index, all.count > 1 else {
            print("space move: skipped (need 2+ desktops)")
            NSApp.terminate(nil)
            return
        }
        let target = all[(index + 1) % all.count]
        Spaces.move(window, to: target)
        after(0.5) { [self] in
            print("space move:", Spaces.of(window) == [target] ? "ok" : "FAILED", "->", Spaces.of(window))
            Spaces.move(window, to: all[index])
            after(0.5) { [self] in
                print("space move back:", Spaces.of(window) == [all[index]] ? "ok" : "FAILED")
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
