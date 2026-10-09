import AppKit
import WebKit

/// Keeps one Shell per app in the config, the palette and the menu. Commands go to the key
/// window's shell. ctrl+alt+← / → cycle through the windows, ctrl+alt+1..9 jump to one.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shells: [Shell] = []
    var configWatcher: FolderWatcher?
    /// The defaults until config.yml is read; the last good config after that.
    var config = Config.fallback
    let palette = Palette()
    let probing = CommandLine.arguments.contains("--probe")
    var probed = false

    /// The key window's shell, else the first one.
    var current: Shell? { shells.first { $0.window.isKeyWindow } ?? shells.first }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.writeDefaults()
        reloadConfig()
        // A broken config at launch still gets the default window.
        if shells.isEmpty { syncShells() }
        // default.yml is ours; only the user's file matters.
        configWatcher = FolderWatcher(Config.dir) { [weak self] paths in
            if paths.contains(where: { $0.hasSuffix("/config.yml") }) { self?.reloadConfig() }
        }
        palette.run = { [weak self] in self?.perform($0.action) }
        palette.isOn = { [weak self] in $0.action == .alwaysOnTop && self?.current?.onTop == true }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Apps

    /// Opens a window per app in the config, repoints one whose folder moved, closes the ones
    /// that left the config. Keeps the focus where it was.
    func syncShells() {
        let apps = Site.apps(config: config)
        let focused = current
        var kept: [Shell] = []
        for app in apps {
            if let shell = shells.first(where: { $0.app.name == app.name }) {
                shell.settings = config.window
                if shell.app.root != app.root { shell.show(app) }
                kept.append(shell)
            } else {
                let shell = Shell(app: app, settings: config.window)
                shell.closed = { [weak self] in self?.forget($0) }
                shell.changed = { [weak self] _ in self?.buildMenu() }
                shell.didLoad = { [weak self] in self?.loaded($0) }
                kept.append(shell)
                shell.open()
            }
        }
        // New windows first, then the old ones go: closing the last window quits the app.
        let gone = shells.filter { shell in !kept.contains { $0 === shell } }
        shells = kept
        gone.forEach { $0.window.close() }
        if let focused, shells.contains(where: { $0 === focused }) {
            focus(focused)
        } else if let first = shells.first {
            focus(first)
        }
        buildMenu()
        if apps.count > 1 { print("apps:", apps.map(\.name)) }
    }

    func forget(_ shell: Shell) {
        shells.removeAll { $0 === shell }
        buildMenu()
    }

    func focus(_ shell: Shell) {
        shell.window.makeKeyAndOrderFront(nil)
        shell.window.makeFirstResponder(shell.webView)
    }

    /// A switch in progress; another one waits for it to finish.
    var sliding = false

    /// Switches to `shell` with a slide: `direction` 1 brings it in from the right (the way
    /// `switch.next` goes), -1 from the left. Both windows move together, like Spaces do, for
    /// `switch.duration` seconds. Without an animation when that is 0, or when the two windows
    /// are not both fullscreen-mode windows on the same screen and Space.
    func focus(_ shell: Shell, direction: Int) {
        guard let from = current, from !== shell else { return focus(shell) }
        let frame = from.window.frame
        let switching = config.switching
        let canSlide = switching.duration > 0 && from.mode == .fullscreen && shell.mode == .fullscreen
            && !from.window.styleMask.contains(.fullScreen) && !shell.window.styleMask.contains(.fullScreen)
            && from.window.screen === shell.window.screen && Spaces.of(from.window) == Spaces.of(shell.window)
        guard canSlide, !sliding else { return focus(shell) }
        sliding = true
        let offset = CGFloat(direction) * frame.width
        shell.window.setFrame(frame.offsetBy(dx: offset, dy: 0), display: true)
        shell.window.orderFront(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = switching.duration
            context.timingFunction = switching.easing.function
            from.window.animator().setFrame(frame.offsetBy(dx: -offset, dy: 0), display: true)
            shell.window.animator().setFrame(frame, display: true)
        }, completionHandler: { [self] in
            focus(shell)
            // Back under the new window, ready for the next switch.
            from.window.setFrame(frame, display: false)
            sliding = false
        })
    }

    /// `switch.next` and `switch.previous`: the next or previous window in config order, wrapping around.
    func step(_ delta: Int) {
        guard let current, let index = shells.firstIndex(where: { $0 === current }), shells.count > 1 else { return }
        let next = shells[(index + delta + shells.count) % shells.count]
        focus(next, direction: delta)
        print("app:", next.app.name)
    }

    @objc func nextApp() { step(1) }
    @objc func previousApp() { step(-1) }

    /// `switch.jump` + N: slides towards the chosen window's place in the list.
    @objc func switchApp(_ sender: NSMenuItem) {
        guard let shell = sender.representedObject as? Shell, let current,
              let from = shells.firstIndex(where: { $0 === current }), let to = shells.firstIndex(where: { $0 === shell })
        else { return }
        focus(shell, direction: to > from ? 1 : -1)
    }

    @objc func closeWindow() { current?.window.close() }

    func loaded(_ shell: Shell) {
        guard probing, !probed, shell === shells.first else { return }
        probed = true
        Task { @MainActor in
            await probeWeb(shell)
            probePalette(shell)
            probeSpaces(shell)
        }
    }

    // MARK: Config and commands

    func reloadConfig() {
        guard let loaded = Config.load() else { return }
        config = loaded
        palette.commands = loaded.controlPlane.commands
        print("config:", loaded.controlPlane.commands.map(\.title), "switch in \(loaded.switching.duration)s")
        syncShells()
    }

    func perform(_ action: Action) {
        guard let shell = current else { return }
        switch action {
        case .quit: NSApp.terminate(nil)
        case .fullscreen: shell.set(.fullscreen)
        case .window: shell.set(.window)
        case .frameless: shell.set(.frameless)
        case .alwaysOnTop: shell.toggleOnTop()
        case .reload: shell.reload()
        case .allDesktops: shell.toggleAllSpaces()
        case .nextDesktop: shell.moveToNextSpace()
        }
    }

    @objc func reload() { current?.reload() }
    @objc func toggleAllSpaces() { current?.toggleAllSpaces() }
    @objc func moveToNextSpace() { current?.moveToNextSpace() }

    @objc func openPalette() {
        guard let shell = current else { return }
        palette.isOpen ? palette.close() : palette.open(over: shell.window)
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? Config.Command { perform(command.action) }
    }

    // MARK: Menu

    /// Shortcuts live in the main menu rather than in a key monitor, so every plain key reaches
    /// the terminal. The Edit menu is what makes ⌘C / ⌘V work inside the web view. The
    /// Commands menu mirrors the config's control plane, with each command's key. The Apps menu
    /// lists the windows; the key one is checked.
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
        let onTop = current?.onTop == true
        let commands = plane.commands.map { command in
            let entry = item(command.title, #selector(runCommand(_:)), command.key?.key ?? "", command.key?.modifiers ?? [])
            entry.representedObject = command
            if command.action == .alwaysOnTop { entry.state = onTop ? .on : .off }
            return entry
        }
        let apps = shells.enumerated().map { index, shell in
            // switch.jump + 1..9; a tenth window and beyond has no key.
            let entry = item(shell.app.name, #selector(switchApp(_:)), index < 9 ? String(index + 1) : "", switching.jump.modifiers)
            entry.representedObject = shell
            entry.state = shell === current ? .on : .off
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
    func probeWeb(_ shell: Shell) async {
        let webView = shell.webView
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
        print("apps:", shells.map { "\($0.app.name) → \($0.app.origin.absoluteString)" })
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
        // Several windows: switching must land on the next one in config order.
        if shells.count > 1 {
            focus(shell)
            nextApp()
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("next app:", current?.app.name ?? "none", current === shells[1] && !sliding ? "ok" : "FAILED")
            previousApp()
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("previous app:", current?.app.name ?? "none", current === shell && !sliding ? "ok" : "FAILED",
                  "frames:", shells.allSatisfy { $0.window.frame == shell.window.frame } ? "aligned" : "FAILED")
        }
    }

    /// `--probe`, palette part: opens it, filters, closes. Nothing is run.
    func probePalette(_ shell: Shell) {
        palette.open(over: shell.window)
        print("palette:", palette.shown.map(\.title), "open:", palette.isOpen)
        palette.type("win")
        print("palette \"win\":", palette.shown.map(\.title))
        palette.close()
        print("palette closed:", !palette.isOpen)
    }

    /// `--probe`, window part: reports the fullscreen frame and whether a Space move sticks, then quits.
    func probeSpaces(_ shell: Shell) {
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
