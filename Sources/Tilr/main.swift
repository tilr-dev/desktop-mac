import AppKit
import WebKit
import Sparkle

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
    let probing = CommandLine.arguments.contains("--probe")
    var probed = false
    var updater: SPUStandardUpdaterController?
    let about = About()

    var tabs: [Tab] { shell.tabs }
    var current: Tab? { shell.current }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Release packaging supplies both values. Local builds never contact an update feed.
        if !probing, !CommandLine.arguments.contains("--no-updates"),
           Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
           Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: about, userDriverDelegate: nil)
        }
        Config.writeDefaults()
        Instance.launched()
        // A broken config at launch keeps the defaults. The mode is read here, once; the rest
        // of window: applies on every config change.
        if let loaded = Config.load() { config = loaded }
        nativePluginSettings = config.nativePlugins
        LocalServerHost.shared.didUpdate = { [weak self] in
            self?.tabs.forEach { $0.send(event: "tilr-local-server-ready", detail: [:]) }
        }
        LocalServerHost.shared.start(settings: config.localServer,
                                    origins: Site.apps(config: config).map { "tilr://\($0.host)" },
                                    allowed: Config.isDefaultDir && !probing)
        debug = DebugMode(settings: config.debug)
        Memory.settings = config.debug
        shell = Shell(settings: config.window)
        shell.changed = { [weak self] _ in self?.buildMenu() }
        applyConfig()
        shell.open()
        // default.yml is ours; only the user's file matters.
        configWatcher = FolderWatcher(Config.dir) { [weak self] paths in
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
                select: { [unowned self] tab in shell.select(tab); buildMenu() },
                debug: debug
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
            // Control is read at launch: a tab made later still follows that choice.
            let tab = Tab(app: app, control: config.control.socket.isEmpty ? nil : config.control, browser: config.browser, native: nativePluginSettings,
                          sshAgent: config.sshAgent, collector: debug.collector)
            tab.nativePlugins.configure(browser: config.browser, options: config.nativePlugins.options)
            tab.didLoad = { [weak self] in self?.loaded($0) }
            tab.show(app)
            return tab
        }
        for tab in tabs where !kept.contains(where: { $0 === tab }) { tab.nativePlugins.stop() }
        shell.setTabs(kept)
        buildMenu()
        if apps.count > 1 { print("apps:", apps.map(\.name)) }
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
        guard let tab = sender.representedObject as? Tab, let current, tab !== current,
              let from = tabs.firstIndex(where: { $0 === current }), let to = tabs.firstIndex(where: { $0 === tab })
        else { return }
        shell.select(tab, direction: to > from ? 1 : -1, switching: config.switching)
        print("app:", tab.app.name)
    }

    @objc func closeWindow() { shell.window.close() }

    func loaded(_ tab: Tab) {
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
            await probeWeb(tab)
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

    /// Shortcuts live in the main menu rather than in a key monitor, so every plain key reaches
    /// the terminal. The Edit menu is what makes ⌘C / ⌘V work inside the web view. The
    /// Commands menu mirrors the config's control plane, with each command's key. The Apps menu
    /// lists the tabs; the current one is checked.
    @objc func showAbout() {
        let plugins = tabs.flatMap { tab in
            tab.nativePlugins.status().map { entry in
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
        let onTop = shell.onTop
        let commands = plane.commands.map { command in
            let entry = item(title(command), #selector(runCommand(_:)), command.key?.key ?? "", command.key?.modifiers ?? [])
            entry.representedObject = command
            if command.action == .alwaysOnTop { entry.state = onTop ? .on : .off }
            return entry
        }
        let apps = tabs.enumerated().map { index, tab in
            // switch.jump + 1..9; a tenth tab and beyond has no key.
            let entry = item(tab.app.name, #selector(switchApp(_:)), index < 9 ? String(index + 1) : "", switching.jump.modifiers)
            entry.representedObject = tab
            entry.state = tab === current ? .on : .off
            return entry
        }
        let check = item("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)), "")
        check.target = updater
        if updater == nil {
            // Keep the menu discoverable in local/preview builds, which have no update feed.
            check.action = nil
            check.isEnabled = false
            check.toolTip = "Updates are available in signed release builds."
        }
        var appItems: [NSMenuItem] = [item("About Tilr", #selector(showAbout), ""), check,
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
        let tab = Tab(app: app, control: config.control, browser: config.browser, native: config.nativePlugins, sshAgent: config.sshAgent)
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
        tab.show(app)
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
                guard let image = try? await webView.takeSnapshot(configuration: config),
                      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
                else { continue }
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(path)-\(name)-\(side).png"))
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
            /// Only the current page is visible and it fills the window; the rest are hidden, no slide left.
            func settled() -> Bool {
                !shell.sliding && tabs.allSatisfy { tab in
                    tab.webView.frame == shell.content.bounds && tab.webView.isHidden == (tab !== current)
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

    /// Regression checks for desktop geometry and the frameless drag / resize boundary.
    func probeWindowGeometry() {
        let originalMode = shell.mode
        shell.set(.window)
        let desktop = shell.window.frame
        let chosen = desktop.insetBy(dx: 20, dy: 20).offsetBy(dx: 10, dy: -10)
        shell.window.setFrame(chosen, display: true)
        shell.set(.frameless)
        precondition(shell.window.frame == chosen, "frameless lost desktop geometry")
        shell.set(.fullscreen)
        shell.set(.window)
        precondition(shell.window.frame == chosen, "fullscreen lost desktop geometry")
        shell.set(.window)
        precondition(shell.window.frame == chosen, "same mode reset geometry")
        shell.set(.frameless)
        let size = shell.window.frame.size
        let border = shell.settings.resizeBorder
        let height = shell.settings.dragHeight
        if height > border && size.width > border * 2 {
            precondition(shell.shouldDrag(at: NSPoint(x: size.width / 2, y: size.height - (height + border) / 2)), "header cannot drag")
        }
        if border > 0 {
            precondition(!shell.shouldDrag(at: NSPoint(x: size.width / 2, y: size.height - border / 2)), "top resize edge drags")
            precondition(!shell.shouldDrag(at: NSPoint(x: border / 2, y: size.height - border / 2)), "resize corner drags")
            precondition(!shell.shouldDrag(at: NSPoint(x: size.width - border / 2, y: size.height - border / 2)), "resize corner drags")
        }
        precondition(!shell.shouldDrag(at: NSPoint(x: size.width / 2, y: size.height / 2)), "body drags")
        shell.set(.window)
        shell.window.setFrame(desktop, display: true)
        shell.set(originalMode)
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
