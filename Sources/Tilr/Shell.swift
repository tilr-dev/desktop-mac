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

enum Mode: String, Codable {
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

/// One native host with one full application page and independent presentation.
final class Shell: NSObject, NSWindowDelegate {
    /// A snapshot of window defaults when this host was created.
    var settings: Config.Windows
    let window = Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    /// Contains this host's single page.
    let content = NSView()
    let hostID: UUID
    private(set) var current: Tab?
    var mode: Mode
    var pending: Mode?
    var allSpaces = false
    var onTop = false
    private var dragMonitor: Any?
    private var dragEvent: NSEvent?
    /// Shared geometry for the two desktop modes; fullscreen never overwrites it.
    private var desktopFrame: NSRect?

    /// The window became key or a toggle flipped; key-host menus mirror it.
    var changed: ((Shell) -> Void)?
    var stateChanged: (() -> Void)?
    var closed: ((Shell) -> Void)?
    private var applyingMode = false

    init(settings: Config.Windows, hostID: UUID = UUID()) {
        self.hostID = hostID
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

    /// Mount exactly one page; a host never switches its app by mounting another page.
    func attach(_ tab: Tab) {
        precondition(current == nil)
        current = tab
        tab.container.frame = content.bounds
        tab.container.autoresizingMask = [.width, .height]
        content.addSubview(tab.container)
        window.title = Instance.title("\(tab.app.name) · \(hostID.uuidString)")
        window.identifier = NSUserInterfaceItemIdentifier(hostID.uuidString)
        tab.loadIfNeeded()
        window.makeFirstResponder(tab.webView)
    }

    var savedFrame: NSRect { desktopFrame ?? window.frame }

    func restore(_ state: WindowRecord) {
        let screens = NSScreen.screens
        let screen = screens.first { WindowRecord.screenID($0) == state.screen } ?? NSScreen.main
        var frame = state.frame.rect
        if !screens.contains(where: { $0.visibleFrame.intersection(frame).width >= 80 && $0.visibleFrame.intersection(frame).height >= 40 }), let screen {
            frame.origin = screen.visibleFrame.origin
            frame.size.width = min(frame.width, screen.visibleFrame.width)
            frame.size.height = min(frame.height, screen.visibleFrame.height)
        }
        window.setFrame(frame, display: false)
        desktopFrame = frame
        mode = state.mode
        onTop = state.onTop
        allSpaces = state.allSpaces
        window.level = onTop ? .screenSaver : .normal
    }

    func restoreSpace(_ space: UInt64?) async {
        guard let space, !allSpaces, !Self.assignedToAllDesktops,
              Spaces.desktopsByDisplay().flatMap({ $0 }).contains(space),
              !Spaces.of(window).contains(space) else { return }
        do {
            try await Spaces.move(window, to: space, timeout: settings.spaceMoveTimeout, interval: settings.spaceMoveInterval)
        } catch { print("host \(hostID): Space restore: \(error.localizedDescription)") }
        stateChanged?()
    }

    // MARK: Window modes

    /// Dock and menu bar hidden only while a fullscreen-mode window is key. App-wide, so the key
    /// window applies it (windowDidBecomeKey).
    var presentationOptions: NSApplication.PresentationOptions {
        mode == .fullscreen ? [.hideDock, .hideMenuBar] : []
    }

    func set(_ new: Mode) {
        applyingMode = true
        defer { applyingMode = false; stateChanged?() }
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
        let leavingFullscreen = mode == .fullscreen && new != .fullscreen
        mode = new
        applyCollectionBehavior()
        let screen = window.screen ?? NSScreen.main!
        let windowFrame = desktopFrame ?? screen.visibleFrame.insetBy(dx: settings.inset.x, dy: settings.inset.y)
        // Presentation options and ordering. Changing the options (Dock and menu bar shown
        // again) makes AppKit put an active app's window back at a frame it remembers (seen on a
        // 1024×768 CI display: fullscreen → window landed on the launch frame), so leaving
        // fullscreen presents first and sets the desktop frame last. Entering, the window covers
        // the screen before the Dock and the menu bar hide.
        func present() {
            if window.isKeyWindow { NSApp.presentationOptions = presentationOptions }
            // Not active and not to take focus (window.activate_at_launch false): shown behind
            // the active app; ordering it front would cover the user's windows.
            if NSApp.isActive || settings.activateAtLaunch {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderBack(nil)
            }
        }
        if leavingFullscreen { present() }
        let presented = window.frame
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
        // The host page follows a content-frame change through autoresizing.
        let applied = window.frame
        if !leavingFullscreen { present() }
        // Safety net: should the system still move the window after the desktop frame, the
        // desktop frame wins; the log says at which step it moved.
        if leavingFullscreen && window.frame != windowFrame {
            print("window: \(new) frame \(window.frame), restoring \(windowFrame);",
                  "after presentation options \(presented), setFrame \(applied)")
            window.setFrame(windowFrame, display: true)
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
        stateChanged?()
    }

    func toggleAllSpaces() {
        allSpaces.toggle()
        applyCollectionBehavior()
        print("show on all desktops:", allSpaces)
        stateChanged?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.presentationOptions = presentationOptions
        changed?(self)
    }

    func windowDidMove(_ notification: Notification) { geometryChanged() }
    func windowDidResize(_ notification: Notification) { geometryChanged() }
    func windowDidChangeScreen(_ notification: Notification) { stateChanged?() }
    private func geometryChanged() {
        guard !applyingMode else { return }
        if mode != .fullscreen { desktopFrame = window.frame }
        stateChanged?()
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
        current?.watcher = nil
        current?.nativePlugins.stop()
        closed?(self)
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
            defer { movingSpace = false; stateChanged?() }
            do {
                try await Spaces.move(window, to: all[target], timeout: timing.spaceMoveTimeout, interval: timing.spaceMoveInterval)
                print("move to desktop \(target + 1): ok")
            } catch { print("move to desktop \(target + 1): \(error.localizedDescription)") }
        }
    }
}
