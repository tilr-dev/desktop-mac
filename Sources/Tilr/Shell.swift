import AppKit
import WebKit
import ObjectiveC

// Private SkyLight calls: AppKit has no public API to read or choose a window's Space. Resolved
// at run time (dlsym), so a macOS without one of them runs the app with Spaces unavailable.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias ManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias BridgeMove = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void
    private typealias Allocate = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    private typealias InitializeMove = @convention(c) (UnsafeMutableRawPointer, Selector, CFArray, UInt64) -> Unmanaged<AnyObject>?
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void

    private struct Calls {
        let cid: Int32
        let active: ActiveSpace
        let displays: ManagedDisplaySpaces
        let spaces: SpacesForWindows
        let move: MoveWindows?
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
              let spaces = symbol("CGSCopySpacesForWindows", SpacesForWindows.self)
        else {
            print("spaces: unavailable on this macOS (SkyLight calls missing)")
            return nil
        }
        return Calls(cid: main(), active: active, displays: displays, spaces: spaces,
                     move: symbol("CGSMoveWindowsToManagedSpace", MoveWindows.self))
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

    /// Newer macOS uses a bridged operation. The legacy function still resolves there,
    /// but its presence alone does not mean that it can move a window.
    private struct Bridge {
        let cls: AnyClass
        let allocate: Allocate
        let initialize: InitializeMove
        let perform: BridgeMove
    }

    private static let bridge: Bridge? = {
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let alloc = class_getClassMethod(cls, NSSelectorFromString("alloc")),
              let initializer = class_getInstanceMethod(cls, NSSelectorFromString("initWithWindows:spaceID:")),
              let perform = class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")),
              method_getNumberOfArguments(perform) == 2,
              method_getNumberOfArguments(initializer) == 4 else { return nil }
        let returnType = method_copyReturnType(perform)
        defer { free(returnType) }
        guard String(cString: returnType) == "v" else { return nil }
        // Refuse an ABI we have not checked rather than casting a changed signature.
        func type(_ index: UInt32?) -> String {
            let value = index.map { method_copyArgumentType(initializer, $0) } ?? method_copyReturnType(initializer)
            guard let value else { return "" }
            defer { free(value) }
            return String(cString: value)
        }
        guard type(nil) == "@", type(2) == "@", type(3) == "Q" else { return nil }
        return Bridge(cls: cls,
                      allocate: unsafeBitCast(method_getImplementation(alloc), to: Allocate.self),
                      initialize: unsafeBitCast(method_getImplementation(initializer), to: InitializeMove.self),
                      perform: unsafeBitCast(method_getImplementation(perform), to: BridgeMove.self))
    }()

    static var moveBackend: String {
        if bridge != nil { return "bridged" }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if (os.majorVersion < 14 || (os.majorVersion == 14 && os.minorVersion < 5)), calls?.move != nil { return "legacy" }
        return "unavailable"
    }

    @MainActor
    static func move(_ window: NSWindow, to space: UInt64, timeout: Double, interval: Double) async throws {
        guard let calls, moveBackend != "unavailable" else {
            throw ControlServer.Failure(message: "Space move unavailable on this macOS")
        }
        guard !window.collectionBehavior.contains(.canJoinAllSpaces), !window.styleMask.contains(.fullScreen) else {
            throw ControlServer.Failure(message: "Space move requires a window on one desktop (not all-desktops or native fullscreen)")
        }
        guard desktopsByDisplay().contains(where: { $0.contains(space) }) else {
            throw ControlServer.Failure(message: "target desktop no longer exists")
        }
        guard timeout.isFinite, interval.isFinite, timeout > 0, interval > 0, interval <= timeout else {
            throw ControlServer.Failure(message: "invalid window.space_move_timeout / space_move_interval")
        }
        let windows = [window.windowNumber] as CFArray
        if let bridge {
            guard let allocated = bridge.allocate(bridge.cls, NSSelectorFromString("alloc")),
                  let operation = bridge.initialize(allocated, NSSelectorFromString("initWithWindows:spaceID:"), windows, space)?.takeRetainedValue() else {
                throw ControlServer.Failure(message: "Space move operation unavailable")
            }
            bridge.perform(Unmanaged.passUnretained(operation).toOpaque(), NSSelectorFromString("performWithWMBridgeDelegate"))
        } else { calls.move?(calls.cid, windows, space) }
        // Submission is asynchronous. Membership is the actual success condition;
        // never report success merely because the call returned.
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if Set(of(window)) == Set([space]) { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while Date() < deadline
        if Set(of(window)) == Set([space]) { return }
        throw ControlServer.Failure(message: "Space move failed: backend=\(moveBackend), target=\(space), actual=\(of(window))")
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
    /// Holds the tabs' containers (`Tab.container`, each filled by its web view); only the
    /// current one is unhidden, fills the content and resizes with it. Hidden ones keep their
    /// last size until shown (`reveal`).
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
            tab.container.removeFromSuperview()
            tab.watcher = nil
        }
        for tab in new where tab.container.superview !== content {
            tab.container.isHidden = true
            tab.container.autoresizingMask = []
            tab.container.frame = content.bounds
            content.addSubview(tab.container)
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
        slideGeneration += 1
        settle()
        tab.loadIfNeeded()
        for other in tabs where other !== tab { conceal(other) }
        reveal(tab, at: content.bounds)
        current = tab
        window.title = Instance.title(tab.app.name)
        window.makeFirstResponder(tab.webView)
        changed?(self)
    }

    /// The slide under way, if any: the tab going out and the one coming in. Set from the
    /// moment the switch is asked for, through the turn before the animation starts, to its end.
    private var slide: (from: Tab, to: Tab)?
    var sliding: Bool { slide != nil }
    /// Counts selects: a slide's deferred start and its completion act only while no other
    /// select has come since (A→B, B→A, A→B in one turn must not start or settle twice).
    private var slideGeneration = 0

    /// Switches to `tab` with a slide: `direction` 1 brings it in from the right (the way
    /// `switch.next` goes), -1 from the left. Both pages move together inside the window, like
    /// Spaces do, for `switching.duration` seconds; 0 switches at once. A switch that comes
    /// while one is under way finishes that one first.
    ///
    /// What moves is the containers' layers (a translation transform animated by Core
    /// Animation), not view frames: the web views keep their frames, so WebKit gets no
    /// view-frame update per animation frame. The incoming page is unhidden (off to the side)
    /// one run loop turn before the animation starts, so WebKit can repaint what it dropped
    /// while hidden.
    func select(_ tab: Tab, direction: Int, switching: Config.Switching) {
        guard let from = current, from !== tab, switching.duration > 0 else { return select(tab) }
        slideGeneration += 1
        let generation = slideGeneration
        settle()
        tab.loadIfNeeded()
        let bounds = content.bounds
        let offset = CGFloat(direction) * bounds.width
        // Neither page follows a resize until the slide settles (which sizes the incoming one).
        from.container.autoresizingMask = []
        reveal(tab, at: bounds, resizing: false)
        setTranslation(tab.container, offset)
        slide = (from, tab)
        current = tab
        window.title = Instance.title(tab.app.name)
        window.makeFirstResponder(tab.webView)
        changed?(self)
        DispatchQueue.main.async { [weak self] in
            // Another switch may have settled this one already; the newest one starts its own.
            guard let self, generation == slideGeneration, slide != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                // An interrupted slide's animations are removed (settle), which completes this
                // transaction early: only the newest slide settles itself.
                guard let self, generation == slideGeneration else { return }
                settle()
            }
            slideLayer(from.container, from: 0, to: -offset, switching)
            slideLayer(tab.container, from: offset, to: 0, switching)
            CATransaction.commit()
        }
    }

    /// Ends the slide under way: the page that came in fills the content, the one that went out hides.
    private func settle() {
        guard let (from, to) = slide else { return }
        slide = nil
        for view in [from.container, to.container] {
            view.layer?.removeAllAnimations()
            setTranslation(view, 0)
        }
        conceal(from)
        reveal(to, at: content.bounds)
    }

    /// Moves `view`'s layer `dx` points sideways, with no animation and no change to its frame.
    private func setTranslation(_ view: NSView, _ dx: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.transform = CATransform3DMakeTranslation(dx, 0, 0)
        CATransaction.commit()
    }

    /// Animates `view`'s layer translation from `start` to `end` points, leaving the model at `end`.
    private func slideLayer(_ view: NSView, from start: CGFloat, to end: CGFloat, _ switching: Config.Switching) {
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DMakeTranslation(start, 0, 0)
        animation.toValue = CATransform3DMakeTranslation(end, 0, 0)
        animation.duration = switching.duration
        animation.timingFunction = switching.easing.function
        layer.transform = CATransform3DMakeTranslation(end, 0, 0)
        layer.add(animation, forKey: "slide")
    }

    /// Unhides `tab`'s page at `frame`. The frame is set before the view shows, so its first
    /// frame on screen has the window's current size, not the one it had when hidden.
    private func reveal(_ tab: Tab, at frame: NSRect, resizing: Bool = true) {
        let view = tab.container
        view.autoresizingMask = []
        if view.frame != frame { view.frame = frame }
        view.isHidden = false
        if resizing { view.autoresizingMask = [.width, .height] }
    }

    /// Hides `tab`'s page; a hidden page does not follow window resizes (each resize of a
    /// WKWebView is work in its WebContent process).
    private func conceal(_ tab: Tab) {
        tab.container.isHidden = true
        tab.container.autoresizingMask = []
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
        // A style change swaps the content view's frame; the current page follows it
        // (autoresizing), a slide under way ends sized to it.
        settle()
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
        let membership = Spaces.of(window)
        let current = membership.count == 1 ? membership.first : nil
        let all = Spaces.desktopsByDisplay().first { list in current.map(list.contains) ?? false }
            ?? Spaces.desktopsByDisplay().first ?? []
        return (all, current.flatMap(all.firstIndex(of:)))
    }

    /// Dock assignment is independent of NSWindow.collectionBehavior and applies to
    /// every copy sharing the app's bundle identifier.
    static var assignedToAllDesktops: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "app-bindings")?[identifier] as? String == "AllSpaces"
    }

    private var movingSpace = false

    func moveToNextSpace() {
        guard !movingSpace else { return }
        guard !allSpaces, !Self.assignedToAllDesktops else {
            print("move to next desktop: unavailable while Show on All Desktops or Dock → Options → Assign To → All Desktops is enabled")
            return
        }
        guard Spaces.available, Spaces.moveBackend != "unavailable" else { return print("Space move unavailable on this macOS") }
        let (all, index) = desktops()
        guard let index, all.count > 1 else {
            print("move to next desktop: skipped (window must be on one desktop, with 2+ desktops available)")
            return
        }
        let target = (index + 1) % all.count
        movingSpace = true
        let timing = settings
        Task { @MainActor [self] in
            defer { movingSpace = false }
            do {
                try await Spaces.move(window, to: all[target], timeout: timing.spaceMoveTimeout, interval: timing.spaceMoveInterval)
                print("move to desktop \(target + 1): ok")
            } catch { print("move to desktop \(target + 1): \(error.localizedDescription)") }
        }
    }
}
