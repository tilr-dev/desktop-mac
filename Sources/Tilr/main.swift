import AppKit
import WebKit

/// Keeps the one window (Shell) with a tab per app in the config, the palette and the menu.
/// ctrl+alt+← / → cycle through the tabs, ctrl+alt+1..9 jump to one.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shell: Shell!
    var configWatcher: FolderWatcher?
    /// The defaults until config.yml is read; the last good config after that.
    var config = Config.fallback
    let palette = Palette()
    let probing = CommandLine.arguments.contains("--probe")
    var probed = false

    var tabs: [Tab] { shell.tabs }
    var current: Tab? { shell.current }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeDefaults()
        // A broken config at launch keeps the defaults. The mode is read here, once; the rest
        // of window: applies on every config change.
        if let loaded = Config.load() { config = loaded }
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
        NSApp.activate(ignoringOtherApps: true)
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
                return tab
            }
            let tab = Tab(app: app)
            tab.didLoad = { [weak self] in self?.loaded($0) }
            tab.show(app)
            return tab
        }
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
            await probeWeb(tab)
            probePalette()
            probeSpaces()
        }
    }

    // MARK: Config and commands

    func reloadConfig() {
        guard let loaded = Config.load() else { return }
        config = loaded
        applyConfig()
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
        }
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
            let entry = item(command.title, #selector(runCommand(_:)), command.key?.key ?? "", command.key?.modifiers ?? [])
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

    /// `--probe`, web part: reports what loaded, clicks through the header's clock menu from JS and,
    /// with `--snapshot PATH`, saves pictures of the top corners of the page.
    @MainActor
    func probeWeb(_ tab: Tab) async {
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
    func probeSpaces() {
        let window = shell.window
        func after(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
        }
        let (all, index) = shell.desktops()
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
        after(0.5) {
            print("space move:", Spaces.of(window) == [target] ? "ok" : "FAILED", "->", Spaces.of(window))
            Spaces.move(window, to: all[index])
            after(0.5) {
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
