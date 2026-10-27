import AppKit
import WebKit
import Sparkle
import AppUpdates
import Gitpm

// Prints reach a log file or a pipe as they happen (run.sh with its output redirected), not in blocks.
setvbuf(stdout, nil, _IOLBF, 0)

/// Keeps the one window (Shell) with a tab per app in the config, the palette and the menu.
/// ctrl+alt+← / → cycle through the tabs, ctrl+alt+1..9 jump to one.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shell: Shell!
    var configWatcher: FolderWatcher?
    /// The defaults until config.yml is read; the last good config after that.
    var config = Config.fallback
    var nativePluginSettings = Config.fallback.nativePlugins
    let palette = Palette()
    var control: ControlServer?
    /// Compatibility settings and JSON export for the single Performance collector.
    var debug: DebugMode!
    /// `plugin_manager:` (PluginManagerHost.swift); its workspace opens on the first operation.
    var pluginManager: PluginManagerService!
    let probing = CommandLine.arguments.contains("--probe")
    var probed = false
    var appUpdates: AppUpdates?
    var updater: SPUStandardUpdaterController? { appUpdates?.controller }
    let about = About()
    /// `switch.preload` as read at launch.
    var preload: Config.Preload = .onSelect
    /// `switch.preload` N: the background load of the other apps has been scheduled.
    var preloadScheduled = false
    /// `switch.preload` N: that background load, until it runs (`--probe` cancels it).
    var preloadWork: DispatchWorkItem?
    /// Menu items whose check mark follows the shell (`updateMenu`): the Apps entries by tab,
    /// and the always-on-top commands.
    var appMenuItems: [NSMenuItem] = []
    var onTopMenuItems: [NSMenuItem] = []

    var tabs: [Tab] { shell.tabs }
    var current: Tab? { shell.current }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Release packaging enables runtime feed selection. Local builds have no update service.
        if !probing, !CommandLine.arguments.contains("--no-updates"),
           Bundle.main.object(forInfoDictionaryKey: "TilrUpdateFeedSelection") as? String == "preferences",
           Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String {
            // Started once the window is up (below), so the first check does not delay it.
            appUpdates = AppUpdates(updaterDelegate: about)
        }
        Config.writeDefaults()
        Instance.launched()
        // A broken config at launch keeps the defaults. The mode is read here, once; the rest
        // of window: applies on every config change.
        if let loaded = Config.load() { config = loaded }
        nativePluginSettings = config.nativePlugins
        preload = config.switching.preload
        pluginManager = PluginManagerService(settings: config.pluginManager.service)
        if !probing {
            let settings = config.pluginManager.service
            Task { await Self.syncPluginDist(settings) }
        }
        LocalServerHost.shared.didUpdate = { [weak self] in
            self?.tabs.forEach { $0.send(event: "tilr-local-server-ready", detail: [:]) }
        }
        LocalServerHost.shared.start(settings: config.localServer,
                                    origins: Site.apps(config: config).map { "tilr://\($0.host)" },
                                    allowed: Config.isDefaultDir && !probing)
        debug = DebugMode(settings: config.debug)
        Memory.settings = config.debug
        shell = Shell(settings: config.window)
        shell.changed = { [weak self] _ in self?.updateMenu() }
        // The window first, empty; the tabs' views are added to it as they are made.
        shell.open()
        applyConfig()
        if let appUpdates { DispatchQueue.main.async { appUpdates.start() } }
        // default.yml is ours; only the user's file matters.
        configWatcher = FolderWatcher(Config.dir, latency: config.watch.latency) { [weak self] paths in
            if paths.contains(where: { $0.hasSuffix("/config.yml") }) { self?.reloadConfig() }
        }
        palette.run = { [weak self] in self?.perform($0.action) }
        palette.isOn = { [weak self] in $0.action == .alwaysOnTop && self?.shell.onTop == true }
        palette.title = { [weak self] in self?.title($0) ?? $0.title }
        if !config.control.socket.isEmpty {
            control = ControlServer(
                path: Config.resolve(config.control.socket),
                tabs: { [unowned self] in tabs },
                current: { [unowned self] in current },
                select: { [unowned self] tab, slide in
                    // No slide to the current app: it is shown at once, as without "slide".
                    if slide && jump(to: tab) { return true }
                    shell.select(tab)
                    return false
                },
                loadTimeout: { [unowned self] in config.control.loadTimeout },
                debug: debug,
                pluginManager: { [unowned self] in try await pluginManagerStatus() }
            )
            control?.start()
        }
        // window.activate_at_launch false (the test instance): the user's app keeps the focus.
        if config.window.activateAtLaunch { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        tabs.forEach { $0.nativePlugins.stop() }
        Instance.terminating()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Apps

    /// A tab per app in the config: repoints one whose folder moved, drops the ones that left
    /// the config, keeps the current one current.
    func syncTabs() {
        let apps = Site.apps(config: config)
        shell.settings = config.window
        let kept = apps.map { app in
            if let tab = tabs.first(where: { $0.app.name == app.name }) {
                if tab.app.root != app.root { tab.show(app) }
                tab.nativePlugins.configure(browser: config.browser, options: config.nativePlugins.options)
                tab.agent.settings = config.sshAgent
                return tab
            }
            return makeTab(app)
        }
        for tab in tabs where !kept.contains(where: { $0 === tab }) { tab.nativePlugins.stop() }
        // Selecting loads the current tab; the others load per switch.preload.
        shell.setTabs(kept)
        if preload == .atLaunch { kept.forEach { $0.loadIfNeeded() } }
        buildMenu()
        if apps.count > 1 { print("apps:", apps.map(\.name)) }
    }

    /// A tab for `app`, its page not loaded yet (`Tab.loadIfNeeded`).
    func makeTab(_ app: Site.App) -> Tab {
        // Control is read at launch: a tab made later still follows that choice.
        let tab = Tab(app: app, control: config.control.socket.isEmpty ? nil : config.control, browser: config.browser, native: nativePluginSettings,
                      sshAgent: config.sshAgent, watchLatency: config.watch.latency, inspectable: config.debug.inspectable, web: config.web,
                      collector: debug.collector)
        tab.nativePlugins.configure(browser: config.browser, options: config.nativePlugins.options)
        tab.didLoad = { [weak self] in self?.loaded($0) }
        tab.didFailLoad = { [weak self] in self?.schedulePreload(after: $0) }
        return tab
    }

    /// `switch.next` and `switch.previous`: the next or previous tab in config order, wrapping around.
    func step(_ delta: Int) {
        guard let current, let index = tabs.firstIndex(where: { $0 === current }), tabs.count > 1 else { return }
        let next = tabs[(index + delta + tabs.count) % tabs.count]
        shell.select(next, direction: delta, switching: config.switching)
        print("app:", next.app.name)
    }

    @objc func nextApp() { step(1) }
    @objc func previousApp() { step(-1) }

    /// `switch.jump` + N: slides towards the chosen tab's place in the list.
    @objc func switchApp(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        jump(to: tab)
    }

    /// Slides to `tab` from the side of its place in the list (`switch.jump`, `ctl switch` with slide).
    /// Returns whether a slide started: none to the current tab, none with `switch.duration` 0.
    @discardableResult
    func jump(to tab: Tab) -> Bool {
        guard let current, tab !== current,
              let from = tabs.firstIndex(where: { $0 === current }), let to = tabs.firstIndex(where: { $0 === tab })
        else { return false }
        shell.select(tab, direction: to > from ? 1 : -1, switching: config.switching)
        print("app:", tab.app.name)
        return shell.sliding
    }

    @objc func closeWindow() { shell.window.close() }

    /// switch.preload N: the other apps load N seconds after the first page on screen is done,
    /// loaded or failed; once.
    func schedulePreload(after tab: Tab) {
        guard case .after(let seconds) = preload, !preloadScheduled, tab === current else { return }
        preloadScheduled = true
        let work = DispatchWorkItem { [weak self] in
            self?.preloadWork = nil
            self?.tabs.forEach { $0.loadIfNeeded() }
        }
        preloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func loaded(_ tab: Tab) {
        schedulePreload(after: tab)
        guard probing, !probed, tab === tabs.first else { return }
        probed = true
        Task { @MainActor in
            do { _ = try await tab.nativePlugins.request(service: "browser", body: ["action": "probe"]) }
            catch {
                print("native browser probe FAILED:", error.localizedDescription)
                Instance.terminating()
                exit(EXIT_FAILURE)
            }
            await probeReloadHistory()
            await probePagePlumbing()
            await probeWeb(tab)
            await probeLazyTabs()
            await probePluginManager()
            probePalette()
            await probeSpaces()
        }
    }

    // MARK: Config and commands

    func reloadConfig() {
        guard let loaded = Config.load() else { return }
        config = loaded
        applyConfig()
        debug.configChanged(config.debug)
        Memory.settings = config.debug
        pluginManager.configure(config.pluginManager.service)
        LocalServerHost.shared.configChanged(settings: config.localServer,
                                             origins: Site.apps(config: config).map { "tilr://\($0.host)" },
                                             allowed: Config.isDefaultDir && !probing)
    }

    func applyConfig() {
        palette.commands = config.controlPlane.commands
        print("config:", config.controlPlane.commands.map(\.title), "switch in \(config.switching.duration)s")
        syncTabs()
    }

    func perform(_ action: Action) {
        switch action {
        case .quit: NSApp.terminate(nil)
        case .fullscreen: shell.set(.fullscreen)
        case .window: shell.set(.window)
        case .frameless: shell.set(.frameless)
        case .alwaysOnTop: shell.toggleOnTop()
        case .reload: current?.reload()
        case .allDesktops: shell.toggleAllSpaces()
        case .nextDesktop: shell.moveToNextSpace()
        case .debug:
            current?.webView.evaluateJavaScript("if (globalThis.tilr?.services?.performance) tilr.services.performance.open(); else alert('Install and enable the Performance web plugin first.')", completionHandler: nil)
        }
    }

    /// The legacy debug action opens the shared Performance window.
    func title(_ command: Config.Command) -> String {
        command.action == .debug ? "Performance…" : command.title
    }

    @objc func reload() { current?.reload() }
    @objc func toggleAllSpaces() { shell.toggleAllSpaces() }
    @objc func moveToNextSpace() { shell.moveToNextSpace() }

    @objc func openPalette() {
        palette.isOpen ? palette.close() : palette.open(over: shell.window)
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? Config.Command { perform(command.action) }
    }

    // MARK: Menu

    @objc func showUpdateSettings() { appUpdates?.showSettings() }

    /// Shortcuts live in the main menu rather than in a key monitor, so every plain key reaches
    /// the terminal. The Edit menu is what makes ⌘C / ⌘V work inside the web view. The
    /// Commands menu mirrors the config's control plane, with each command's key. The Apps menu
    /// lists the tabs; the current one is checked.
    @objc func showAbout() {
        let plugins = tabs.flatMap { tab in
            // An app not loaded yet (switch.preload) has not started its providers: nothing to report.
            tab.nativePlugins.status().filter { $0["state"] as? String != "pending" }.map { entry in
                let id = entry["id"] as? String ?? "Unknown"
                if let version = entry["version"] as? String {
                    let publisher = entry["publisher"] as? String == "third-party" ? " · third-party" : ""
                    return "\(id) \(version) — loaded\(publisher)"
                }
                return "\(tab.app.name): \(id) — \(entry["error"] as? String ?? "unavailable")"
            }
        }
        about.show(updater: updater, pluginStatus: Array(Set(plugins)).sorted())
    }
    @objc func showLocalServer() { LocalServerHost.shared.showStatus() }
    @objc func checkServerUpdates() { LocalServerHost.shared.checkUpdates(userInitiated: true) }
    @objc func showNativePluginSettings() {
        Config.writeDefaults()
        NSWorkspace.shared.open(Config.file)
    }

    /// The check marks of the Apps entries and the always-on-top commands; what changes when the
    /// window becomes key, a tab is selected or a toggle flips. The menu itself is built per config.
    func updateMenu() {
        for item in appMenuItems { item.state = item.representedObject as? Tab === current ? .on : .off }
        for item in onTopMenuItems { item.state = shell.onTop ? .on : .off }
    }

    /// The whole main menu, on each config change (the apps, the commands, the shortcuts).
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
        let plane = config.controlPlane
        let switching = config.switching
        let commands = plane.commands.map { command in
            let entry = item(title(command), #selector(runCommand(_:)), command.key?.key ?? "", command.key?.modifiers ?? [])
            entry.representedObject = command
            return entry
        }
        onTopMenuItems = zip(plane.commands, commands).filter { $0.0.action == .alwaysOnTop }.map(\.1)
        let apps = tabs.enumerated().map { index, tab in
            // switch.jump + 1..9; a tenth tab and beyond has no key.
            let entry = item(tab.app.name, #selector(switchApp(_:)), index < 9 ? String(index + 1) : "", switching.jump.modifiers)
            entry.representedObject = tab
            return entry
        }
        appMenuItems = apps
        let check = item("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)), "")
        check.target = updater
        if updater == nil {
            // Keep the menu discoverable in local/preview builds, which have no update feed.
            check.action = nil
            check.isEnabled = false
            check.toolTip = "Updates are available in signed release builds."
        }
        let updateSettings = item("Update Settings…", #selector(showUpdateSettings), "")
        if appUpdates == nil {
            updateSettings.action = nil
            updateSettings.isEnabled = false
        }
        var appItems: [NSMenuItem] = [item("About Tilr", #selector(showAbout), ""), check, updateSettings,
                                    item("Native Plugin Settings…", #selector(showNativePluginSettings), ""),
                                    item("Local Server…", #selector(showLocalServer), ""),
                                    item("Check for Server Updates…", #selector(checkServerUpdates), ""), .separator()]
        appItems.append(item("Quit Tilr", #selector(NSApplication.terminate(_:)), "q"))
        submenu("Tilr", appItems)
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
            item("Control Plane", #selector(openPalette), plane.hotkey.key, plane.hotkey.modifiers),
            .separator(),
        ] + commands)
        submenu("View", [
            item("Reload", #selector(reload), "r"),
            .separator(),
            item("Show on All Desktops", #selector(toggleAllSpaces), "a", [.command, .shift]),
            item("Move to Next Desktop", #selector(moveToNextSpace), "s", [.command, .shift]),
        ])
        submenu("Apps", [
            item("Next App", #selector(nextApp), switching.next.key, switching.next.modifiers),
            item("Previous App", #selector(previousApp), switching.previous.key, switching.previous.modifiers),
            item("Close Window", #selector(closeWindow), "w"),
            .separator(),
        ] + apps)
        NSApp.mainMenu = main
        updateMenu()
    }

    // MARK: Probe

    /// Exercise real WebKit navigation, including installing into an empty folder.
    @MainActor
    func probeReloadHistory() async {
        guard Site.devURL == nil else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-history-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = Site.App(name: "history-probe", root: root)
        let tab = Tab(app: app, control: config.control, browser: config.browser, native: config.nativePlugins, sshAgent: config.sshAgent,
                      watchLatency: config.watch.latency, inspectable: config.debug.inspectable, web: config.web)
        func loaded() async {
            for _ in 0..<200 {
                if tab.isLoaded { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            preconditionFailure("Reload history probe timed out")
        }
        func cleanHistory() {
            precondition(!tab.webView.canGoBack && !tab.webView.canGoForward, "Reload added navigation history")
        }
        tab.loadIfNeeded()
        tab.watcher = nil // Drive changes explicitly so each assertion observes one navigation.
        await loaded()
        let placeholder = tab.webView
        let index = root.appendingPathComponent("index.html")
        try! "<html><body>first</body></html>".write(to: index, atomically: true, encoding: .utf8)
        tab.siteChanged([index.path])
        await loaded()
        precondition(tab.webView !== placeholder, "Placeholder history survived installation")
        cleanHistory()
        let page = tab.webView
        _ = try? await page.evaluateJavaScript("localStorage.setItem('reload-probe', 'saved'); window.probeMarker = true")
        try! "<html><body>second</body></html>".write(to: index, atomically: true, encoding: .utf8)
        tab.siteChanged([index.path])
        await loaded()
        precondition(tab.webView === page, "Index edit unnecessarily replaced WebView")
        let fresh = try? await page.evaluateJavaScript("document.body.textContent === 'second' && window.probeMarker === undefined && localStorage.getItem('reload-probe') === 'saved'") as? Bool
        precondition(fresh == true, "Index edit did not fully reload or lost storage")
        cleanHistory()
        tab.reload()
        await loaded()
        cleanHistory()
        try! FileManager.default.removeItem(at: index)
        tab.siteChanged([index.path])
        await loaded()
        precondition(tab.webView !== page, "Removed index kept app history")
        cleanHistory()
        try! "<html><body>third</body></html>".write(to: index, atomically: true, encoding: .utf8)
        tab.siteChanged([index.path])
        await loaded()
        let saved = try? await tab.webView.evaluateJavaScript("localStorage.getItem('reload-probe')") as? String
        precondition(saved == "saved", "Replacing WebView lost persistent storage")
        _ = try? await tab.webView.evaluateJavaScript("localStorage.removeItem('reload-probe')")
        cleanHistory()
        print("reload history: index edit, manual reload, placeholder transitions, persistent storage: ok")
    }

    /// `--probe`, the page's plumbing on a temporary app: the scheme handler (files, directories,
    /// SPA fallback, missing files, MIME types, a double reload), native → page events (`Tab.send`
    /// and `NativePluginSession.emit` deliver the detail unchanged), the console relay (batched,
    /// in order, cut at `control.console_entry_max`, objects serialized only up to the cut),
    /// snapshot PNGs, `debug.inspectable`, the `web.high_refresh_rate` switch and the host
    /// settings handed to the browser plugin.
    @MainActor
    func probePagePlumbing() async {
        guard Site.devURL == nil else { return print("skipped (dev server)") }
        /// Release builds drop a precondition's message: say it, then fail.
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            guard !ok else { return }
            print("page plumbing: FAILED", message())
            Instance.terminating()
            exit(EXIT_FAILURE)
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("tilr-plumbing-\(UUID().uuidString)")
        try! files.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        for (name, text) in [("index.html", "<html><body>root</body></html>"), ("dir/index.html", "dir"), ("a.js", "1"), ("b.css", "x{}"),
                             ("c.xml", "<x/>"), ("d.xyz", "?")] {
            try! text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let tab = Tab(app: Site.App(name: "plumbing-probe", root: root), control: config.control, browser: config.browser,
                      native: config.nativePlugins, sshAgent: config.sshAgent, watchLatency: config.watch.latency,
                      inspectable: config.debug.inspectable, web: config.web)
        defer { tab.nativePlugins.stop() }
        func loaded() async {
            await tab.firstLoad(within: config.control.loadTimeout)
            check(tab.isLoaded, "the page did not load")
        }
        func js(_ body: String) async -> Any? {
            do { return try await tab.webView.callAsyncJavaScript(body, contentWorld: .page) }
            catch { check(false, "\(error)"); return nil }
        }
        tab.loadIfNeeded()
        tab.watcher = nil
        await loaded()
        check(tab.webView.isInspectable == config.debug.inspectable, "debug.inspectable not applied")

        // Scheme handler.
        let served = await js("""
            const get = async (path) => { try { const r = await fetch(path); return [r.headers.get('content-type'), await r.text()] } catch { return 'missing' } }
            const out = {}
            for (const path of ['/a.js', '/b.css', '/c.xml', '/d.xyz', '/dir', '/dir/', '/route', '/missing.png']) out[path] = await get(path)
            return JSON.stringify(out)
            """) as? String ?? ""
        let expected: [String: Any] = [
            "/a.js": ["text/javascript", "1"], "/b.css": ["text/css", "x{}"], "/c.xml": ["application/xml", "<x/>"],
            "/d.xyz": ["application/octet-stream", "?"], "/dir": ["text/html", "dir"], "/dir/": ["text/html", "dir"],
            "/route": ["text/html", "<html><body>root</body></html>"], "/missing.png": "missing",
        ]
        let got = (try? JSONSerialization.jsonObject(with: Data(served.utf8))) as? NSDictionary
        check(got == expected as NSDictionary, "scheme handler served \(served)")
        // Reloads while the last one still loads its many files: WebKit stops their tasks, which
        // must not be answered after that.
        let assets = (0..<40).map { "<script src=\"/a.js?\($0)\"></script><link rel=stylesheet href=\"/b.css?\($0)\">" }.joined()
        try! "<html><body>root\(assets)</body></html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        for _ in 0..<3 { tab.reload() }
        await loaded()
        tab.reload()
        tab.webView.stopLoading()
        tab.reload()
        await loaded()

        // Native → page events: the page gets exactly the JSON the native side made.
        let detail: [String: Any] = ["text": "quote \" newline \n sep \u{2028} </script>", "n": 1.5, "i": 7, "flag": true, "none": NSNull(),
                                     "list": [1, "two", false], "nested": ["k": "v"], "big": String(repeating: "A", count: 100_000)]
        _ = await js("window.__probeEvents = []; for (const name of ['tilr-probe-send', 'tilr-probe-emit']) addEventListener(name, e => __probeEvents.push([name, e.detail]))")
        tab.send(event: "tilr-probe-send", detail: detail)
        tab.nativePlugins.emit("tilr-probe-emit", detail: detail)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let events = await js("return JSON.stringify(__probeEvents)") as? String ?? ""
        let received = (try? JSONSerialization.jsonObject(with: Data(events.utf8))) as? [[Any]] ?? []
        check(received.count == 2 && received.allSatisfy { ($0.last as? NSDictionary) == detail as NSDictionary }
                     && received.map { $0.first as? String } == ["tilr-probe-send", "tilr-probe-emit"],
                     "events arrived as \(events.prefix(300))")

        // Console relay.
        if config.control.consoleCapture {
            let max = config.control.consoleEntryMax
            tab.console.removeAll()
            _ = await js("console.log('one'); console.warn('two', {a: 1}); console.error('x'.repeat(\(max + 100)))")
            try? await Task.sleep(nanoseconds: 200_000_000)
            let entries = tab.console.entries
            check(entries.map(\.type) == ["log", "warn", "error"] && entries.prefix(2).map(\.text) == ["one", "two {\"a\":1}"]
                         && entries.last?.text == String(repeating: "x", count: max) + "…",
                         "console caught \(entries.map { ($0.type, $0.text.prefix(40), $0.text.count) })")
            check(entries.allSatisfy { abs($0.time - Date().timeIntervalSince1970) < 60 }, "console times are off")

            // Objects are serialized only up to the cut, and the kept text is a full
            // JSON.stringify's cut (toJSON, omitted members, boxed values, shared objects, ...).
            tab.console.removeAll()
            let expected = await js("""
                const max = \(max), shared = { q: [1, { z: 2 }], e: {} }, sparse = [1, , 3]; sparse.x = 5
                const cases = [
                  [{ a: shared, b: shared, c: [shared, {}], d: [], u: undefined, f: () => 1, n: NaN, z: -0 }],
                  [sparse, new Map([[1, 2]]), new Date(0), { toJSON: k => ({ key: k }) }],
                  [[undefined, () => 1, Symbol('s')], { s: new String('s'), b: new Boolean(false), n: new Number(2) }],
                  ['lead', { big: 'y'.repeat(max * 2) }, 'tail'],
                  [{ text: 'quote " newline \\n \\u2028 😀'.repeat(max) }],
                  [undefined], [() => 1],
                ]
                let reads = 0
                const counted = Array.from({ length: 50000 }, (_, i) => ({ get v() { reads++; return i } }))
                const cut = text => text.length > max ? text.slice(0, max) + '…' : text
                const full = args => cut(args.map(a => typeof a === 'string' ? a : JSON.stringify(a) ?? String(a)).join(' '))
                for (const args of cases) console.log(...args)
                console.log(counted)
                return JSON.stringify({ texts: cases.map(full), reads })
                """) as? String ?? ""
            try? await Task.sleep(nanoseconds: 200_000_000)
            let want = (try? JSONSerialization.jsonObject(with: Data(expected.utf8))) as? [String: Any] ?? [:]
            let texts = want["texts"] as? [String] ?? []
            let caught = tab.console.entries.map(\.text)
            check(!texts.isEmpty && Array(caught.prefix(texts.count)) == texts,
                  "console serialization: \(zip(caught, texts).filter { $0 != $1 }.map { ($0.prefix(60), $1.prefix(60)) })")
            let reads = want["reads"] as? Int ?? .max
            check(caught.count == texts.count + 1 && caught.last?.hasSuffix("…") == true && reads <= max,
                  "console serialization is not bounded: \(reads) getter reads for a \(max)-character entry")
        }

        // web.high_refresh_rate: WebKit's 60 Hz switch can be turned off (on a throwaway
        // preferences object, whatever the config says); with the key on, the page has it off.
        // The rate itself depends on the display the window is on: checked by hand (CLAUDE.md).
        check(WebKitFeatures.set(WebKitFeatures.near60FPS, enabled: false, on: WKPreferences()),
              "WebKit feature \(WebKitFeatures.near60FPS) unavailable")
        check((tab.highRefreshRate as? Bool) == config.web.highRefreshRate, "web.high_refresh_rate not applied: \(tab.highRefreshRate)")
        let pluginBrowser = tab.nativePlugins.configuration["browser"] as? [String: Any] ?? [:]
        check(pluginBrowser["inspectable"] as? Bool == config.debug.inspectable
              && pluginBrowser["high_refresh_rate"] as? Bool == config.web.highRefreshRate,
              "the browser plugin's host settings: \(pluginBrowser)")

        // Snapshot → PNG off the main thread.
        let png = files.temporaryDirectory.appendingPathComponent("tilr-plumbing-\(UUID().uuidString).png")
        defer { try? files.removeItem(at: png) }
        do {
            // The page as the window shows it (the probe's own page has no window to be drawn in).
            guard let shown = current?.webView else { return check(false, "snapshot: no current page") }
            let image = try await shown.takeSnapshot(configuration: nil)
            try await PNG.write(image, to: png)
        } catch { check(false, "snapshot: \(error)") }
        let header = (try? Data(contentsOf: png))?.prefix(8)
        check(header == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "snapshot is not a PNG")
        print("page plumbing: scheme handler, double reload, native events, console relay and its bounded serialization, high refresh rate switch, plugin host settings, snapshot PNG: ok")
    }

    /// `--probe`, web part: reports what loaded, clicks through the header's clock menu from JS and,
    /// with `--snapshot PATH`, saves pictures of the top corners of the page.
    @MainActor
    func probeWeb(_ tab: Tab) async {
        probeWindowGeometry()
        let webView = tab.webView
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
                guard let image = try? await webView.takeSnapshot(configuration: config) else { continue }
                try? await PNG.write(image, to: URL(fileURLWithPath: "\(path)-\(name)-\(side).png"))
            }
        }
        // Lets fonts and layout settle before measuring.
        try? await Task.sleep(nanoseconds: 700_000_000)
        print("apps:", tabs.map { "\($0.app.name) → \($0.app.origin.absoluteString)" })
        print("page:", webView.url?.absoluteString ?? "none")
        if webView.url?.lastPathComponent == "placeholder.html" {
            let welcome = await js("document.querySelector('h1')?.textContent ?? ''")
            precondition(welcome.contains("Tilr"), "Bundled welcome page failed to load")
            print("bundled welcome page: ok")
            await snapshot("welcome")
            return
        }
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
        // The SSH agent bridge (Agent.swift): a probe answers either way; with an agent, a
        // connection asks it for its identities (00 00 00 01 0b) and expects the answer (type 0c).
        let agent = try? await webView.callAsyncJavaScript("""
            const next = (match) => new Promise(resolve => {
              const timer = setTimeout(() => { removeEventListener('tilr-agent', on); resolve(null); }, 3000);
              const on = (e) => { if (!match(e.detail)) return; clearTimeout(timer); removeEventListener('tilr-agent', on); resolve(e.detail); };
              addEventListener('tilr-agent', on);
            });
            const post = (m) => webkit.messageHandlers.tilrAgent.postMessage(m);
            const ready = next(d => d.type === 'ready'); post({ op: 'probe' });
            const r = await ready;
            if (!r) return 'FAILED no ready event';
            if (!r.available) return 'ready ' + JSON.stringify(r) + ' (no agent: round-trip skipped)';
            const id = 'probe-' + Date.now();
            const opened = next(d => d.id === id); post({ op: 'open', id });
            const o = await opened;
            if (o?.type !== 'open') return 'ready ' + JSON.stringify(r) + ' open FAILED ' + JSON.stringify(o);
            const answer = next(d => d.id === id); post({ op: 'data', id, data: btoa('\\x00\\x00\\x00\\x01\\x0b') });
            const a = await answer;
            post({ op: 'close', id });
            const bytes = a?.type === 'data' ? atob(a.data) : '';
            const ok = bytes.length >= 5 && bytes.charCodeAt(4) === 0x0c;
            return 'ready ' + JSON.stringify(r) + ' identities ' + (ok ? 'ok, ' + bytes.length + ' bytes' : 'FAILED ' + JSON.stringify(a));
            """, contentWorld: .page) as? String
        print("ssh agent:", agent ?? "FAILED js error")
        // Several apps: switching must land on the next tab in config order, in the one window,
        // in every mode; the pages must then be at rest with only the current one showing.
        if tabs.count > 1 {
            /// Only the current page is visible, fills the window and follows its size; the rest
            /// are hidden and do not (switch: resizing hidden pages is WebContent work), no slide left.
            func unmoved(_ tab: Tab) -> Bool {
                tab.container.layer.map { CATransform3DIsIdentity($0.transform) && $0.animation(forKey: "slide") == nil } ?? false
            }
            func settled() -> Bool {
                !shell.sliding && tabs.allSatisfy { tab in
                    tab === current
                        ? tab.container.frame == shell.content.bounds && !tab.container.isHidden
                            && tab.container.autoresizingMask == [.width, .height] && unmoved(tab)
                            && tab.webView.frame == tab.container.bounds
                        : tab.container.isHidden && tab.container.autoresizingMask == [] && unmoved(tab)
                }
            }
            shell.select(tab)
            for mode in [Mode.fullscreen, .window, .frameless] {
                shell.set(mode)
                try? await Task.sleep(nanoseconds: 200_000_000)
                nextApp()
                try? await Task.sleep(nanoseconds: 500_000_000)
                print("\(mode) next app:", current?.app.name ?? "none", current === tabs[1] && settled() ? "ok" : "FAILED")
                previousApp()
                try? await Task.sleep(nanoseconds: 500_000_000)
                print("\(mode) previous app:", current?.app.name ?? "none", current === tab && settled() ? "ok" : "FAILED",
                      "windows:", NSApp.windows.filter(\.isVisible).count == 1 ? "one" : "FAILED \(NSApp.windows.filter(\.isVisible).count)")
            }
            shell.set(config.window.mode)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// `--probe`, lazy loading (switch.preload): an app that is listed but not selected has no
    /// page, no folder watcher and no started native providers; selecting it loads it. A second
    /// app (a temporary folder) is added next to the config's for the check and removed after.
    @MainActor
    func probeLazyTabs() async {
        guard Site.devURL == nil, let first = current else { return print("lazy tabs: skipped (dev server)") }
        if preload == .onSelect {
            precondition(tabs.allSatisfy { $0 === first || !$0.started }, "switch.preload false loaded an unselected app")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-lazy-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try! "<html><body>lazy</body></html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        // switch.preload N must not load the temporary app behind the check's back: no
        // background load from here on (the probe quits after).
        preloadScheduled = true
        preloadWork?.cancel()
        preloadWork = nil
        let original = tabs
        let extra = makeTab(Site.App(name: "lazy-probe", root: root))
        shell.setTabs(original + [extra])
        buildMenu()
        let pending = extra.nativePlugins.status().allSatisfy { $0["state"] as? String == "pending" }
        precondition(current === first && !extra.started && extra.webView.url == nil && extra.watcher == nil && pending,
                     "an unselected app loaded its page")
        shell.select(extra, direction: 1, switching: config.switching)
        precondition(extra.started && extra.watcher != nil, "selecting an app did not load it")
        await extra.firstLoad(within: config.control.loadTimeout)
        let body = try? await extra.webView.evaluateJavaScript("document.body.textContent") as? String
        precondition(extra.isLoaded && extra.webView.url == extra.pageURL && body == "lazy", "the selected app's page did not load")
        // A hidden page does not follow a window resize; it gets the new size when shown, at once
        // or at the end of a slide.
        shell.select(first)
        let frame = shell.window.frame
        shell.window.setFrame(frame.insetBy(dx: 30, dy: 20), display: true)
        precondition(first.container.frame == shell.content.bounds && first.webView.frame == first.container.bounds,
                     "the current page did not follow the window")
        precondition(extra.container.isHidden && extra.container.frame != shell.content.bounds, "a hidden page followed the window")
        shell.select(extra)
        precondition(extra.container.frame == shell.content.bounds && extra.container.autoresizingMask == [.width, .height]
                     && extra.webView.frame == extra.container.bounds
                     && first.container.isHidden && first.container.autoresizingMask == [], "a shown page has the old size")
        shell.window.setFrame(frame, display: true)
        shell.select(first, direction: -1, switching: config.switching)
        // During the slide the pages' layers move, never a view frame (no geometry update for WebKit).
        if config.switching.duration > 0 {
            let frames = (first.container.frame, extra.container.frame, first.webView.frame, extra.webView.frame)
            try? await Task.sleep(nanoseconds: UInt64(config.switching.duration / 2 * 1_000_000_000))
            precondition(shell.sliding && !first.container.isHidden && !extra.container.isHidden
                         && first.container.layer?.animation(forKey: "slide") != nil
                         && frames == (first.container.frame, extra.container.frame, first.webView.frame, extra.webView.frame),
                         "a slide moved view frames or is not under way")
        }
        try? await Task.sleep(nanoseconds: UInt64((config.switching.duration * 2 + 0.1) * 1_000_000_000))
        precondition(!shell.sliding && first.container.frame == shell.content.bounds && !first.container.isHidden
                     && first.container.autoresizingMask == [.width, .height] && first.webView.frame == first.container.bounds
                     && CATransform3DIsIdentity(first.container.layer?.transform ?? CATransform3DIdentity)
                     && CATransform3DIsIdentity(extra.container.layer?.transform ?? CATransform3DIdentity)
                     && extra.container.isHidden, "a slide did not settle at the window's size")
        shell.setTabs(original)
        extra.nativePlugins.stop()
        buildMenu()
        print("lazy tabs: unselected app not loaded, loads on select, hidden page not resized: ok")
    }

    /// Regression checks for desktop geometry and the frameless drag / resize boundary.
    func probeWindowGeometry() {
        let originalMode = shell.mode
        /// Release builds drop a precondition's message: say it with the numbers, then fail.
        func check(_ ok: Bool, _ step: String, _ expected: NSRect? = nil) {
            guard !ok else { return }
            let screen = NSScreen.main
            print("window geometry: FAILED \(step): expected \(expected.map { "\($0)" } ?? "-") actual \(shell.window.frame)",
                  "screen \(screen.map { "\($0.frame)" } ?? "none") visible \(screen.map { "\($0.visibleFrame)" } ?? "none")",
                  "fullScreen \(shell.window.styleMask.contains(.fullScreen)) mode \(shell.mode)")
            Instance.terminating()
            exit(EXIT_FAILURE)
        }
        /// A mode switch changes the content view's frame: the current page follows it.
        func set(_ mode: Mode) {
            shell.set(mode)
            check(current.map { $0.container.frame == shell.content.bounds && $0.webView.frame == $0.container.bounds } ?? true,
                  "the current page did not follow the \(mode) content")
        }
        set(.window)
        let desktop = shell.window.frame
        let chosen = desktop.insetBy(dx: 20, dy: 20).offsetBy(dx: 10, dy: -10)
        shell.window.setFrame(chosen, display: true)
        set(.frameless)
        check(shell.window.frame == chosen, "after window → frameless", chosen)
        set(.fullscreen)
        set(.window)
        check(shell.window.frame == chosen, "after fullscreen → window", chosen)
        set(.window)
        check(shell.window.frame == chosen, "after window → window", chosen)
        set(.frameless)
        let size = shell.window.frame.size
        let border = shell.settings.resizeBorder
        let height = shell.settings.dragHeight
        if height > border && size.width > border * 2 {
            check(shell.shouldDrag(at: NSPoint(x: size.width / 2, y: size.height - (height + border) / 2)), "header cannot drag")
        }
        if border > 0 {
            check(!shell.shouldDrag(at: NSPoint(x: size.width / 2, y: size.height - border / 2)), "top resize edge drags")
            check(!shell.shouldDrag(at: NSPoint(x: border / 2, y: size.height - border / 2)), "resize corner drags")
            check(!shell.shouldDrag(at: NSPoint(x: size.width - border / 2, y: size.height - border / 2)), "resize corner drags")
        }
        check(!shell.shouldDrag(at: NSPoint(x: size.width / 2, y: size.height / 2)), "body drags")
        set(.window)
        shell.window.setFrame(desktop, display: true)
        set(originalMode)
        print("window geometry and drag boundaries: ok")
    }

    /// `--probe`, palette part: opens it, filters, closes. Nothing is run.
    func probePalette() {
        palette.open(over: shell.window)
        print("palette:", palette.shown.map(\.title), "open:", palette.isOpen)
        palette.type("win")
        print("palette \"win\":", palette.shown.map(\.title))
        palette.close()
        print("palette closed:", !palette.isOpen)
    }

    /// `--probe`, window part: reports the fullscreen frame and whether a Space move sticks, then quits.
    @MainActor
    func probeSpaces() async {
        let window = shell.window
        guard Spaces.available, Spaces.moveBackend != "unavailable" else {
            print("space move: unavailable")
            NSApp.terminate(nil)
            return
        }
        let (all, index) = shell.desktops()
        print("Spaces probe bundle:", Bundle.main.bundleIdentifier ?? "none", "Dock All Desktops:", Shell.assignedToAllDesktops)
        guard Spaces.of(window).count == 1 else {
            print("space move: FAILED precondition: window belongs to multiple/no desktops; use ./run.sh --test --probe to isolate Dock assignment")
            control?.stop()
            Instance.terminating()
            exit(EXIT_FAILURE)
        }
        print("screen frame:", (window.screen ?? NSScreen.main!).frame)
        print("window frame:", window.frame)
        print("presentation options:", NSApp.currentSystemPresentationOptions.rawValue)
        print("desktops:", all, "membership:", Spaces.of(window), "backend:", Spaces.moveBackend,
              "collection behavior:", window.collectionBehavior.rawValue)
        guard let index, all.count > 1 else {
            print("space move: skipped (requires window on one desktop and 2+ desktops)")
            NSApp.terminate(nil)
            return
        }
        let target = all[(index + 1) % all.count]
        var failures: [String] = []
        for (label, destination) in [("space move", target), ("space move back", all[index])] {
            do {
                try await Spaces.move(window, to: destination, timeout: config.window.spaceMoveTimeout, interval: config.window.spaceMoveInterval)
                print("\(label): ok ->", Spaces.of(window))
            } catch {
                failures.append(error.localizedDescription)
                print("\(label): FAILED:", error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            control?.stop()
            Instance.terminating()
            exit(EXIT_FAILURE)
        }
        NSApp.terminate(nil)
    }

}

// Validate signatures, ABI and factories without WindowServer or starting services.
// Useful for installers/CI; does not modify configuration or a running instance.
if let index = CommandLine.arguments.firstIndex(of: "--check-native-plugin") {
    do {
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw NativePluginFailure(message: "--check-native-plugin needs a package path")
        }
        guard let config = Config.load() else { throw NativePluginFailure(message: "invalid configuration") }
        try NativePluginLibrary.checkPackage(URL(fileURLWithPath: CommandLine.arguments[index + 1]), allowThirdParty: config.nativePlugins.allowThirdParty)
        exit(EXIT_SUCCESS)
    } catch {
        print("native plugin check FAILED:", error.localizedDescription)
        exit(EXIT_FAILURE)
    }
}
if CommandLine.arguments.contains("--check-native-plugins") {
    do {
        let config = Config.load() ?? Config.fallback
        for id in config.nativePlugins.enabled {
            let library = try NativePluginLibrary.open(id: id, directory: URL(fileURLWithPath: Config.resolve(config.nativePlugins.directory)), allowThirdParty: config.nativePlugins.allowThirdParty)
            let plugin = try library.make()
            plugin.stop()
            print("native plugin check: \(id) \(library.manifest.version) ABI \(plugin.abiVersion) ← \(library.url.path)")
        }
        exit(EXIT_SUCCESS)
    } catch {
        print("native plugin check FAILED:", error.localizedDescription)
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
