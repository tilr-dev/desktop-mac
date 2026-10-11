import AppKit
import WebKit

// Private SkyLight calls: AppKit has no public API to read or choose a window's Space. Resolved
// at run time (dlsym), so a macOS without one of them runs the app with Spaces unavailable.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias ManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void

    private struct Calls {
        let cid: Int32
        let active: ActiveSpace
        let displays: ManagedDisplaySpaces
        let spaces: SpacesForWindows
        let move: MoveWindows
    }

    /// nil when a symbol is missing on this macOS.
    private static let calls: Calls? = {
        let handle = dlopen(nil, RTLD_NOW)
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let main = symbol("CGSMainConnectionID", MainConnection.self),
              let active = symbol("CGSGetActiveSpace", ActiveSpace.self),
              let displays = symbol("CGSCopyManagedDisplaySpaces", ManagedDisplaySpaces.self),
              let spaces = symbol("CGSCopySpacesForWindows", SpacesForWindows.self),
              let move = symbol("CGSMoveWindowsToManagedSpace", MoveWindows.self)
        else {
            print("spaces: unavailable on this macOS (SkyLight calls missing)")
            return nil
        }
        return Calls(cid: main(), active: active, displays: displays, spaces: spaces, move: move)
    }()

    static var available: Bool { calls != nil }

    /// Desktop Spaces (type 0, i.e. not fullscreen ones) per display, in Mission Control order.
    static func desktopsByDisplay() -> [[UInt64]] {
        guard let calls else { return [] }
        let displays = calls.displays(calls.cid)?.takeRetainedValue() as? [[String: Any]] ?? []
        return displays.map { display in
            (display["Spaces"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? Int) == 0 }
                .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
    }

    static func active() -> UInt64? { calls.map { $0.active($0.cid) } }

    static func of(_ window: NSWindow) -> [UInt64] {
        guard let calls else { return [] }
        let ids = calls.spaces(calls.cid, 7, [window.windowNumber] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []
        return ids.map(\.uint64Value)
    }

    static func move(_ window: NSWindow, to space: UInt64) {
        guard let calls else { return }
        calls.move(calls.cid, [window.windowNumber] as CFArray, space)
    }
}

enum Mode: String, Decodable {
    /// Covers the whole screen in the current Space, Dock and menu bar hidden.
    case fullscreen
    /// A normal window with a title bar.
    case window
    /// A window without a title bar; dragged by its top `drag_height` points (the page's header bar).
    case frameless
}

/// Borderless windows refuse key status by default, which would leave the app without keyboard input.
final class Window: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The one window. The apps are its tabs (see Tab), stacked in the content view with one of them
/// visible; a switch slides the next one in over the whole content, so the mode, the frame, the
/// Space and always-on-top are shared and nothing shows that the apps are separate pages. Owns
/// the window's mode, its Space settings and the drag in frameless mode.
final class Shell: NSObject, NSWindowDelegate {
    /// `window:` from the config; the owner updates it when the config changes.
    var settings: Config.Windows
    let window = Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    /// Holds the tabs' web views, all the size of the content; only the current one is unhidden.
    let content = NSView()
    private(set) var tabs: [Tab] = []
    private(set) var current: Tab?
    var mode: Mode
    var pending: Mode?
    var allSpaces = false
    var onTop = false
    private var dragMonitor: Any?
    private var dragEvent: NSEvent?
    /// Shared geometry for the two desktop modes; fullscreen never overwrites it.
    private var desktopFrame: NSRect?

    /// The window became key, a tab was chosen or a toggle flipped; the menu mirrors them.
    var changed: ((Shell) -> Void)?

    init(settings: Config.Windows) {
        self.settings = settings
        mode = settings.mode
        super.init()
        window.title = Instance.title("Tilr")
        window.delegate = self
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        content.wantsLayer = true
        content.clipsToBounds = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content
        installDrag()
    }

    /// Shows the window in the config's mode.
    func open() {
        set(mode)
    }

    // MARK: Tabs

    /// Replaces the tabs with `new`, keeping the ones already there (by identity). The current
    /// one stays if it is still listed; else the first one is shown.
    func setTabs(_ new: [Tab]) {
        for tab in tabs where !new.contains(where: { $0 === tab }) {
            tab.webView.removeFromSuperview()
            tab.watcher = nil
        }
        for tab in new where tab.webView.superview !== content {
            tab.webView.frame = content.bounds
            tab.webView.isHidden = true
            content.addSubview(tab.webView)
        }
        tabs = new
        if let current, tabs.contains(where: { $0 === current }) {
            select(current)
        } else if let first = tabs.first {
            select(first)
        } else {
            current = nil
        }
    }

    /// Shows `tab` at once, with no slide.
    func select(_ tab: Tab) {
        settle()
        for other in tabs {
            other.webView.isHidden = other !== tab
            other.webView.frame = content.bounds
        }
        current = tab
        window.title = Instance.title(tab.app.name)
        window.makeFirstResponder(tab.webView)
        changed?(self)
    }

    /// The slide under way, if any: the tab going out and the one coming in.
    private var slide: (from: Tab, to: Tab)?
    var sliding: Bool { slide != nil }

    /// Switches to `tab` with a slide: `direction` 1 brings it in from the right (the way
    /// `switch.next` goes), -1 from the left. Both pages move together inside the window, like
    /// Spaces do, for `switching.duration` seconds; 0 switches at once. A switch that comes
    /// while one is under way finishes that one first.
    func select(_ tab: Tab, direction: Int, switching: Config.Switching) {
        guard let from = current, from !== tab, switching.duration > 0 else { return select(tab) }
        settle()
        let bounds = content.bounds
        let offset = CGFloat(direction) * bounds.width
        tab.webView.frame = bounds.offsetBy(dx: offset, dy: 0)
        tab.webView.isHidden = false
        slide = (from, tab)
        current = tab
        window.title = Instance.title(tab.app.name)
        window.makeFirstResponder(tab.webView)
        changed?(self)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = switching.duration
            context.timingFunction = switching.easing.function
            from.webView.animator().frame = bounds.offsetBy(dx: -offset, dy: 0)
            tab.webView.animator().frame = bounds
        }, completionHandler: { [weak self] in
            // Another switch may have settled this one already.
            guard let self, let slide, slide.to === tab else { return }
            settle()
        })
    }

    /// Ends the slide under way: the page that came in fills the content, the one that went out hides.
    private func settle() {
        guard let (from, to) = slide else { return }
        slide = nil
        from.webView.layer?.removeAllAnimations()
        to.webView.layer?.removeAllAnimations()
        from.webView.isHidden = true
        from.webView.frame = content.bounds
        to.webView.frame = content.bounds
    }

    // MARK: Window modes

    /// Dock and menu bar hidden only while a fullscreen-mode window is key. App-wide, so the key
    /// window applies it (windowDidBecomeKey).
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
        if mode != .fullscreen && window.frame.width > 0 && window.frame.height > 0 {
            desktopFrame = window.frame
        }
        mode = new
        applyCollectionBehavior()
        let screen = window.screen ?? NSScreen.main!
        let windowFrame = desktopFrame ?? screen.visibleFrame.insetBy(dx: settings.inset.x, dy: settings.inset.y)
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
        // A style change swaps the content view's frame; the pages follow it.
        settle()
        tabs.forEach { $0.webView.frame = content.bounds }
        NSApp.presentationOptions = presentationOptions
        // Not active and not to take focus (window.activate_at_launch false): shown behind the
        // active app; ordering it front would cover the user's windows.
        if NSApp.isActive || settings.activateAtLaunch {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderBack(nil)
        }
        if let current { window.makeFirstResponder(current.webView) }
    }

    /// Frameless mode has no title bar to grab, so a drag that starts in the top `drag_height`
    /// points moves the window. Reserve the perimeter for AppKit's resize handling.
    func shouldDrag(at point: NSPoint) -> Bool {
        let bounds = NSRect(origin: .zero, size: window.frame.size)
        let interior = bounds.insetBy(dx: settings.resizeBorder, dy: settings.resizeBorder)
        return mode == .frameless && interior.contains(point)
            && bounds.height - point.y <= settings.dragHeight
    }

    private func installDrag() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, mode == .frameless, event.window === window else { return event }
            if event.type == .leftMouseDown {
                dragEvent = shouldDrag(at: event.locationInWindow) ? event : nil
            } else if event.type == .leftMouseUp {
                dragEvent = nil
            } else if let start = dragEvent {
                // Clicks reach the clock; once movement starts AppKit owns the gesture.
                // It may consume mouse-up, so clear our state before handing it over.
                dragEvent = nil
                window.performDrag(with: start)
                return nil
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
        print("always on top:", onTop)
        changed?(self)
    }

    func toggleAllSpaces() {
        allSpaces.toggle()
        applyCollectionBehavior()
        print("show on all desktops:", allSpaces)
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
        tabs.forEach { $0.watcher = nil }
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
        guard Spaces.available else { return print("Space move unavailable on this macOS") }
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
