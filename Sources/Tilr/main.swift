import AppKit
import WebKit
import Sparkle
import AppUpdates
import Gitpm
import ObjectiveC

// Prints reach a log file or a pipe as they happen (run.sh with its output redirected), not in blocks.
setvbuf(stdout, nil, _IOLBF, 0)

/// Owns native app hosts, shared services, the palette and key-window menus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shells: [Shell] = []
    var activeShell: Shell?
    var shell: Shell! { activeShell ?? shells.first }
    var restoringWindows = false
    var terminating = false
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
    var probing = CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--probe-shell-control")
    var probed = false
    var appUpdates: AppUpdates?
    private var uninstalling = false
    let about = About()
    /// Menu items whose check mark follows the shell (`updateMenu`): the Apps entries by tab,
    /// and the always-on-top commands.
    var appMenuItems: [NSMenuItem] = []
    var onTopMenuItems: [NSMenuItem] = []
    var hostMenuItem: NSMenuItem?

    var tabs: [Tab] { shells.compactMap(\.current) }
    var current: Tab? { shell?.current }

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
        restoreWindows(WindowWorkspace.read())
        applyConfig()
        if let appUpdates { DispatchQueue.main.async { appUpdates.start() } }
        // default.yml is ours; only the user's file matters.
        configWatcher = FolderWatcher(Config.dir, latency: config.watch.latency) { [weak self] paths in
            if paths.contains(where: { $0.hasSuffix("/config.yml") }) { self?.reloadConfig() }
        }
        palette.run = { [weak self] in self?.perform($0.action) }
        palette.isOn = { [weak self] in $0.action == .alwaysOnTop && self?.shell?.onTop == true }
        palette.title = { [weak self] in self?.title($0) ?? $0.title }
        if !config.control.socket.isEmpty {
            control = ControlServer(
                path: Config.resolve(config.control.socket),
                shells: { [unowned self] in shells },
                openWindow: { [unowned self] app, frame in openWindow(app, frame: frame) },
                tabs: { [unowned self] in tabs },
                current: { [unowned self] in current },
                select: { [unowned self] tab, _ in focus(tab); return false },
                apps: { [unowned self] in Site.apps(config: config) },
                resolve: { [unowned self] name in windowForApp(name)?.current },
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
        saveWindows()
        terminating = true
        control?.stop()
        tabs.forEach { $0.nativePlugins.stop() }
        Instance.terminating()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Apps

    func saveWindows() {
        guard !restoringWindows, !terminating, !shells.isEmpty else { return }
        WindowWorkspace(key: shell?.hostID, windows: shells.map(WindowRecord.init)).write()
    }

    func restoreWindows(_ saved: WindowWorkspace?) {
        restoringWindows = true
        let apps = Site.apps(config: config)
        var seen: Set<UUID> = []
        for state in saved?.windows ?? [] where state.frame.valid && seen.insert(state.host).inserted {
            guard let app = apps.first(where: { $0.name == state.app }) else { continue }
            let host = openWindow(app, state: state)
            Task { @MainActor [weak host] in await host?.restoreSpace(state.space) }
        }
        if shells.isEmpty, let app = apps.first { openWindow(app) }
        if let host = shells.first(where: { $0.hostID == saved?.key }) { focus(host.current!) }
        restoringWindows = false
        saveWindows()
    }

    @discardableResult
    func openWindow(_ app: Site.App, state: WindowRecord? = nil, frame: NSRect? = nil) -> Shell {
        let host = Shell(settings: config.window, hostID: state?.host ?? UUID())
        shells.append(host)
        if let state { host.restore(state) }
        host.changed = { [weak self, weak host] _ in
            guard let self, let host else { return }
            if host.window.isKeyWindow { activeShell = host }
            updateMenu()
            saveWindows()
        }
        host.stateChanged = { [weak self] in self?.saveWindows() }
        host.closed = { [weak self] host in
            guard let self else { return }
            // Keep the final workspace across the existing last-window termination policy.
            if shells.count == 1 { saveWindows() }
            shells.removeAll { $0 === host }
            if activeShell === host { activeShell = shells.first }
            saveWindows()
            updateMenu()
            print("host \(host.hostID): closed")
        }
        // Attach before callbacks can persist a newly visible host.
        let primaryHost = shells.first(where: { $0 === host || $0.current?.app.name == app.name }) === host
        host.attach(makeTab(app, hostID: host.hostID, primaryHost: primaryHost))
        if frame != nil { host.mode = .window }
        host.open()
        if let frame { host.window.setFrame(frame, display: true) }
        if activeShell == nil || host.window.isKeyWindow { activeShell = host }
        print("host \(host.hostID): opened \(app.name)")
        saveWindows()
        return host
    }

    func focus(_ tab: Tab) {
        guard let host = shells.first(where: { $0.current === tab }) else { return }
        activeShell = host
        host.window.makeKeyAndOrderFront(nil)
        host.window.makeFirstResponder(tab.webView)
        updateMenu()
        saveWindows()
    }

    @discardableResult
    func windowForApp(_ name: String) -> Shell? {
        if let shell, shell.current?.app.name == name { return shell }
        for window in NSApp.orderedWindows {
            if let host = shells.first(where: { $0.window === window && $0.current?.app.name == name }) { return host }
        }
        if let host = shells.first(where: { $0.current?.app.name == name }) { return host }
        guard let app = Site.apps(config: config).first(where: { $0.name == name }) else { return nil }
        return openWindow(app)
    }

    func syncTabs() {
        let apps = Site.apps(config: config)
        if !shells.contains(where: { host in apps.contains { $0.name == host.current?.app.name } }), let app = apps.first {
            openWindow(app)
        }
        for host in shells {
            guard let tab = host.current else { continue }
            guard let app = apps.first(where: { $0.name == tab.app.name }) else { host.window.close(); continue }
            if tab.app.root != app.root { tab.show(app) }
            tab.nativePlugins.configure(browser: config.browser, options: config.nativePlugins.options)
            tab.agent.settings = config.sshAgent
        }
        buildMenu()
        saveWindows()
    }

    /// A tab for `app`, its page not loaded yet (`Tab.loadIfNeeded`).
    func makeTab(_ app: Site.App, hostID: UUID, primaryHost: Bool) -> Tab {
        // Control is read at launch: a tab made later still follows that choice.
        let tab = Tab(app: app, control: config.control.socket.isEmpty ? nil : config.control, browser: config.browser, native: nativePluginSettings,
                      sshAgent: config.sshAgent, watchLatency: config.watch.latency, inspectable: config.debug.inspectable, web: config.web,
                      collector: debug.collector, hostID: hostID, primaryHost: primaryHost)
        tab.nativePlugins.configure(browser: config.browser, options: config.nativePlugins.options)
        tab.didLoad = { [weak self] in self?.loaded($0) }
        return tab
    }

    /// Application selection follows configured order; it focuses or creates native hosts.
    func step(_ delta: Int) {
        let apps = Site.apps(config: config)
        guard let current, let index = apps.firstIndex(where: { $0.name == current.app.name }), !apps.isEmpty,
              let host = windowForApp(apps[(index + delta + apps.count) % apps.count].name) else { return }
        focus(host.current!)
    }

    @objc func nextApp() { step(1) }
    @objc func previousApp() { step(-1) }
    @objc func switchApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let host = windowForApp(name) else { return }
        focus(host.current!)
    }

    @objc func closeWindow() { shell?.window.close() }
    @objc func newWindow() {
        guard let app = current?.app ?? Site.apps(config: config).first else { return }
        let host = openWindow(app)
        focus(host.current!)
    }

    func loaded(_ tab: Tab) {
        guard probing, !probed, tab === tabs.first else { return }
        probed = true
        Task { @MainActor in
            await probeShellControl()
            if CommandLine.arguments.contains("--probe-shell-control") {
                control?.stop()
                Instance.terminating()
                exit(EXIT_SUCCESS)
            }
            await probeWindows()
            do { _ = try await tab.nativePlugins.request(service: "browser", body: ["action": "probe"]) }
            catch {
                print("native browser probe FAILED:", error.localizedDescription)
                Instance.terminating()
                exit(EXIT_FAILURE)
            }
            await probeReloadHistory()
            await probePagePlumbing()
            await probeWeb(tab)
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
        if !palette.commands.contains(where: { $0.action == .newWindow }) {
            palette.commands.append(Config.Command(title: "New Window", action: .newWindow, key: nil))
        }
        print("config:", config.controlPlane.commands.map(\.title))
        syncTabs()
    }

    func perform(_ action: Action) {
        if shell == nil && action != .quit && action != .newWindow { return }
        switch action {
        case .quit: NSApp.terminate(nil)
        case .newWindow: newWindow()
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
    @objc func toggleAllSpaces() { shell?.toggleAllSpaces() }
    @objc func moveToNextSpace() { shell?.moveToNextSpace() }

    @objc func openPalette() {
        if shell == nil { newWindow() }
        guard let shell else { return }
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
    /// lists open pages; the key window is checked.
    @objc func showAbout() {
        let plugins = tabs.flatMap { tab in
            // A page not yet loaded has not started its providers.
            tab.nativePlugins.status().filter { $0["state"] as? String != "pending" }.map { entry in
                let id = entry["id"] as? String ?? "Unknown"
                if let version = entry["version"] as? String {
                    let publisher = entry["publisher"] as? String == "third-party" ? " · third-party" : ""
                    return "\(id) \(version) — loaded\(publisher)"
                }
                return "\(tab.app.name): \(id) — \(entry["error"] as? String ?? "unavailable")"
            }
        }
        about.show(appUpdates: appUpdates, pluginStatus: Array(Set(plugins)).sorted())
    }
    @objc func showLocalServer() { LocalServerHost.shared.showStatus() }

    @objc func uninstallTilr() {
        guard !uninstalling, Config.isDefaultDir, !probing else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Tilr?"
        alert.informativeText = "Tilr will remove its settings, plugins and web data, move this application to Trash, and quit. Shared tilrd state, tokens, logs and running sessions are kept. If tilrd was installed independently, you will be asked whether to remove it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall Tilr").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        uninstalling = true
        Task { @MainActor in
            do {
                guard Bundle.main.bundleURL.pathExtension == "app",
                      let identifier = Bundle.main.bundleIdentifier else {
                    throw ServerInstallation.Failure("Uninstall requires an application bundle.")
                }
                let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
                let uninstall = AppUninstall(bundle: Bundle.main.bundleURL, dataDirectories: [
                    Config.defaultDir,
                    library.appendingPathComponent("Caches/" + identifier),
                    library.appendingPathComponent("WebKit/" + identifier),
                    library.appendingPathComponent("Saved Application State/" + identifier + ".savedState"),
                ])
                try await uninstall.run(removeServer: {
                    try await LocalServerHost.shared.removeForAppUninstall(settings: self.config.localServer)
                }, stop: {
                    self.configWatcher = nil
                    LocalServerHost.shared.stop()
                    self.control?.stop()
                    self.tabs.forEach { $0.webView.stopLoading(); $0.nativePlugins.stop() }
                    await self.pluginManager.close()
                    await withCheckedContinuation { (reply: CheckedContinuation<Void, Never>) in
                        Instance.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                            reply.resume()
                        }
                    }
                }, cleanPreferences: {
                    UserDefaults.standard.removePersistentDomain(forName: identifier)
                })
                NSApp.terminate(nil)
            } catch {
                uninstalling = false
                let failure = NSAlert()
                failure.messageText = "Tilr was not uninstalled"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }
    }
    @objc func showNativePluginSettings() {
        Config.writeDefaults()
        NSWorkspace.shared.open(Config.file)
    }

    /// The check marks of the Apps entries and the always-on-top commands; what changes when the
    /// window becomes key, a tab is selected or a toggle flips. The menu itself is built per config.
    func updateMenu() {
        hostMenuItem?.title = shell.map { "Host: \($0.hostID.uuidString)" } ?? "No open host"
        for item in appMenuItems { item.state = item.representedObject as? String == current?.app.name ? .on : .off }
        for item in onTopMenuItems { item.state = shell?.onTop == true ? .on : .off }
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
        let apps = Site.apps(config: config).enumerated().map { index, app in
            // switch.jump + 1..9; a tenth tab and beyond has no key.
            let entry = item(app.name, #selector(switchApp(_:)), index < 9 ? String(index + 1) : "", switching.jump.modifiers)
            entry.representedObject = app.name
            return entry
        }
        appMenuItems = apps
        let check = item("Check for Updates…", #selector(AppUpdates.checkForUpdates(_:)), "")
        check.target = appUpdates
        if appUpdates == nil {
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
                                    .separator()]
        let uninstall = item("Uninstall Tilr…", #selector(uninstallTilr), "")
        if !Config.isDefaultDir || probing { uninstall.action = nil; uninstall.isEnabled = false }
        appItems.append(uninstall)
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
        let hostLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hostMenuItem = hostLabel
        submenu("Apps", [
            hostLabel,
            item("Next App", #selector(nextApp), switching.next.key, switching.next.modifiers),
            item("Previous App", #selector(previousApp), switching.previous.key, switching.previous.modifiers),
            item("New Window", #selector(newWindow), "n"),
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
        precondition(placeholder.acceptsFirstMouse(for: nil) && tab.webView.acceptsFirstMouse(for: nil),
                     "A page view does not take the first click in an inactive window")
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
        print("reload history: index edit, manual reload, placeholder transitions, persistent storage, first click on a replaced view: ok")
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
        // A click in an inactive window reaches the page (a header drag starts on the first press).
        check(tab.webView.acceptsFirstMouse(for: nil), "the page view does not take the first click in an inactive window")

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
        print("page plumbing: first click, scheme handler, double reload, native events, console relay and its bounded serialization, high refresh rate switch, plugin host settings, snapshot PNG: ok")
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
    }

    /// Observe activation requests without stealing focus from the person running the probe.
    @MainActor
    func probeBackgroundFocus(_ page: Tab) {
        let method = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)))!
        var activations = 0
        let observe: @convention(block) (NSApplication, Bool) -> Void = { _, _ in activations += 1 }
        let replacement = imp_implementationWithBlock(observe)
        let original = method_setImplementation(method, replacement)
        let wasProbing = probing
        probing = false
        defer {
            probing = wasProbing
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        focus(page)
        precondition(activations == 0, "window focus requested application activation")
        precondition(current === page, "background focus did not select the host")
        print("native windows: background focus preserves application activation")
    }

    /// Exercise the same dispatcher used by socket requests against real native windows.
    @MainActor
    func probeShellControl() async {
        guard let control, let initial = shell, let page = initial.current else { preconditionFailure("no Control host") }
        do {
            let count = shells.count
            let rect: [String: Any] = ["x": 90, "y": 120, "width": 540, "height": 380]
            let opened = try await control.run("shell", ["op": "open", "app": page.app.name, "frame": rect])
            guard let id = opened["host"] as? String, let host = shells.first(where: { $0.hostID.uuidString == id }) else { preconditionFailure("open did not return a host") }
            precondition(shells.count == count + 1 && host !== initial && host.current !== page)
            precondition(host.window.frame == NSRect(x: 90, y: 120, width: 540, height: 380))
            let listed = try await control.run("shell", ["op": "list"])["windows"] as! [[String: Any]]
            precondition(listed.count == count + 1)
            precondition(listed.contains { $0["host"] as? String == id && $0["app"] as? String == page.app.name && $0["space"] is [UInt64] && $0["key"] is Bool && $0["frame"] is [String: Any] })
            _ = try await control.run("shell", ["op": "focus", "host": id])
            precondition(current === host.current)
            let catalog = try await control.run("apps", [:])["apps"] as! [[String: Any]]
            let ids = catalog.first { $0["name"] as? String == page.app.name }?["hosts"] as! [String]
            precondition(ids.contains(id) && ids.contains(initial.hostID.uuidString))
            _ = try await control.run("eval", ["host": id, "js": "globalThis.__controlHostProbe = 781"])
            let isolated = try await control.run("eval", ["host": initial.hostID.uuidString, "js": "typeof globalThis.__controlHostProbe"])
            precondition(isolated["value"] as? String == "undefined")
            let routed = try await control.run("eval", ["app": page.app.name, "js": "globalThis.__controlHostProbe"])
            precondition((routed["value"] as? NSNumber)?.intValue == 781)
            let before = initial.window.frame
            _ = try await control.run("shell", ["op": "move", "host": id, "frame": ["x": 110, "y": 130, "width": 560, "height": 400]])
            precondition(host.window.frame == NSRect(x: 110, y: 130, width: 560, height: 400) && initial.window.frame == before)
            for (cmd, request): (String, [String: Any]) in [
                ("apps", ["host": "missing"]), ("plugin-manager", ["host": "missing"]),
                ("eval", ["host": id, "app": "not-this-app", "js": "1"]),
                ("shell", ["op": "close"]), ("shell", ["op": "focus", "host": "missing"]),
                ("shell", ["op": "open", "app": page.app.name, "frame": ["x": 0, "y": 0, "width": -1, "height": 10]]),
                ("shell", ["op": "move", "host": id, "frame": ["x": true, "y": 0, "width": 10, "height": 10]])
            ] {
                do { _ = try await control.run(cmd, request); preconditionFailure("invalid request succeeded: \(cmd)") }
                catch { precondition(!error.localizedDescription.isEmpty) }
            }
            precondition(shells.count == count + 1)
            _ = try await control.run("shell", ["op": "close", "host": id])
            precondition(shells.count == count && shells.contains { $0 === initial })
            focus(page)
            print("shell control: open/list/focus/move/close, host isolation, app routing and invalid requests: ok")
        } catch { preconditionFailure("shell control: \(error)") }
    }

    /// Read identity from a real main page after event-based navigation completion.
    @MainActor
    func probeHostIdentity(_ host: Shell, primary: Bool, reload: Bool = false) async {
        let page = host.current!
        if reload {
            // This later document-start script must already see the native identity.
            page.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
                window.__tilrHostAtStart = window.__tilrHost;
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            page.reload()
        }
        await page.firstLoad(within: config.control.loadTimeout)
        precondition(page.isLoaded, "host identity probe page failed to load")
        let valid = try? await page.webView.evaluateJavaScript("""
            (() => {
              const identity = window.__tilrHost;
              const descriptor = Object.getOwnPropertyDescriptor(window, '__tilrHost');
              return identity?.host === '\(host.hostID.uuidString)'
                && identity.primary === \(primary ? "true" : "false")
                && Object.isFrozen(identity) && descriptor.writable === false
                && descriptor.configurable === false
                && (\(reload ? "true" : "false") ? window.__tilrHostAtStart === identity : true);
            })()
            """) as? Bool
        precondition(valid == true, "runtime host identity is missing, mutable or inconsistent")
    }

    /// Integration probe: real duplicate pages, independent hosts and durable restoration.
    @MainActor
    func probeWindows() async {
        guard let first = shell, let page = first.current else { preconditionFailure("no initial host") }
        probeBackgroundFocus(page)
        await probeHostIdentity(first, primary: true)
        await probeHostIdentity(first, primary: true, reload: true)
        precondition(!page.container.isHidden, "initial host page is hidden")
        var screenState = WindowRecord(first)
        screenState.screen = 1
        screenState.frame = WindowRecord.Frame(NSRect(x: 100, y: 100, width: 500, height: 300))
        let left = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let right = NSRect(x: 1024, y: 0, width: 1024, height: 768)
        let moved = screenState.restoredFrame(displays: [(id: 1, frame: right), (id: 2, frame: left)], fallback: left)
        precondition(right.contains(moved), "rearranged displays lost saved screen identity")
        let fallback = screenState.restoredFrame(displays: [(id: 2, frame: right)], fallback: right)
        precondition(right.contains(fallback), "disconnected screen produced an unreachable host")
        let original = shells
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-windows-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        newWindow()
        let second = shell!
        precondition(!second.current!.container.isHidden, "new host page is hidden")
        precondition(second.hostID != first.hostID && second.current !== page)
        await probeHostIdentity(second, primary: false)
        precondition((second.window.tabbedWindows?.count ?? 0) <= 1 && (first.window.tabbedWindows?.count ?? 0) <= 1, "native hosts became tabs")
        precondition(second.current!.webView.configuration.websiteDataStore === page.webView.configuration.websiteDataStore)
        let firstFrame = first.window.frame
        let firstMode = first.mode
        let firstOnTop = first.onTop
        second.set(.window)
        let frame = NSRect(x: 80, y: 100, width: 540, height: 380)
        second.window.setFrame(frame, display: true)
        await probeNativeFullscreen(second, desktop: frame)
        second.set(.frameless)
        if !second.onTop { second.toggleOnTop() }
        second.toggleAllSpaces()
        precondition(first.window.frame == firstFrame && first.mode == firstMode && first.onTop == firstOnTop)
        precondition(second.window.frame == frame && second.mode == .frameless && second.onTop)
        focus(second.current!)
        precondition(current === second.current && windowForApp(page.app.name) === second)
        precondition(appMenuItems.contains { $0.state == .on && $0.representedObject as? String == page.app.name })
        precondition(hostMenuItem?.title.contains(second.hostID.uuidString) == true)
        // The palette command uses the same dispatcher as all configured command rows.
        guard let command = palette.commands.first(where: { $0.action == .newWindow }) else { preconditionFailure("no New Window palette command") }
        palette.run(command)
        let third = shell!
        precondition(third !== second && third !== first)
        let state = WindowWorkspace(key: second.hostID, windows: [WindowRecord(second), WindowRecord(third)])
        state.write(to: url)
        guard let saved = WindowWorkspace.read(from: url), saved.windows.count == 2 else { preconditionFailure("workspace roundtrip") }
        await probeWindowAgentClose(second)
        precondition(shells.contains { $0 === first } && shells.contains { $0 === third })
        third.window.close()
        precondition(shells.count == original.count)
        restoreWindows(saved)
        guard let restored = shells.first(where: { $0.hostID == saved.windows[0].host }),
              let restoredThird = shells.first(where: { $0.hostID == saved.windows[1].host }) else { preconditionFailure("restore window set") }
        precondition(shells.count == original.count + 2 && shell === restored)
        precondition(restored.window.frame == frame && restored.mode == .frameless && restored.onTop && restored.allSpaces)
        precondition(!restored.current!.container.isHidden, "restored host page is hidden")
        precondition(restored.current !== page && restored.current!.webView !== page.webView)
        precondition(restoredThird.current !== restored.current)
        await probeHostIdentity(restored, primary: false)
        await probeHostIdentity(restoredThird, primary: false)
        let storedMode = config.window.mode
        config.window.mode = .fullscreen
        syncTabs()
        precondition(restored.mode == .frameless && restored.window.frame == frame, "config reset a live host")
        config.window.mode = storedMode
        restored.window.close()
        restoredThird.window.close()
        focus(page)
        if let other = Site.apps(config: config).first(where: { $0.name != page.app.name }) {
            let count = shells.count
            let opened = windowForApp(other.name)!
            focus(opened.current!)
            precondition(current?.app.name == other.name && windowForApp(other.name) === opened)
            if shells.count > count { opened.window.close() }
            focus(page)
        }
        print("native windows: duplicate, independent presentation, close, restore and switch: ok")
    }

    /// Exercise the native-fullscreen delegate contract without depending on desktop activation.
    @MainActor
    func probeNativeFullscreen(_ host: Shell, desktop: NSRect) async {
        host.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: host.window))
        host.window.setFrame((host.window.screen ?? NSScreen.main!).frame, display: true)
        host.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: host.window))
        let state = WindowRecord(host)
        precondition(state.mode == .fullscreen && state.frame.rect == desktop, "native fullscreen lost presentation or desktop frame")
        host.window.setFrame(desktop, display: true)
        host.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: host.window))
        let restored = openWindow(host.current!.app, state: state)
        precondition(restored.mode == .fullscreen && restored.savedFrame == desktop)
        restored.set(.window)
        precondition(restored.window.frame == desktop, "restored fullscreen lost desktop geometry")
        restored.window.close()
        focus(host.current!)
    }

    /// A real stream must release its socket when its host closes, while other hosts survive.
    @MainActor
    func probeWindowAgentClose(_ host: Shell) async {
        let path = "/tmp/tilr-agent-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(listener, 1) == 0)
        let agent = host.current!.agent
        agent.settings.socket = path
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            agent.send = { detail in
                guard detail["id"] as? String == "window-close" else { return }
                precondition(detail["type"] as? String == "open", "agent fixture did not connect")
                ready.resume()
            }
            agent.handle(["op": "open", "id": "window-close"])
        }
        let peer = accept(listener, nil, nil)
        precondition(peer >= 0 && agent.connectionCount == 1)
        defer { Darwin.close(peer) }
        host.window.close()
        precondition(agent.connectionCount == 0, "closed host retained agent connections")
        let eof = await withCheckedContinuation { (closed: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                var byte: UInt8 = 0
                closed.resume(returning: Darwin.read(peer, &byte, 1) == 0)
            }
        }
        precondition(eof, "closed host retained its agent socket")
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
