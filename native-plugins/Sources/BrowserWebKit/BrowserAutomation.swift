import AppKit
import WebKit

/// A separate content world keeps frame handles and element refs out of the visited page.
/// Commands arrive only through the local control socket, not a page message handler.
final class BrowserAutomation: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "tilr-browser-automation")
    weak var webView: WKWebView?
    var timeout: Double
    var privateInput: Bool
    var inputInterval: Double
    private var frames: [String: WKFrameInfo] = [:]

    init(timeout: Double, privateInput: Bool, inputInterval: Double) {
        self.timeout = timeout; self.privateInput = privateInput; self.inputInterval = inputInterval
    }

    func install(_ controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: "tilrBrowserFrame")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: Self.world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // A document leaving (pagehide: navigation, iframe removal) drops its frame handle.
        if let gone = (message.body as? [String: Any])?["gone"] as? String {
            frames.removeValue(forKey: gone)
            return
        }
        guard let id = message.body as? String else { return }
        if message.frameInfo.isMainFrame { frames.removeAll() }
        frames[id] = message.frameInfo
    }

    @MainActor
    func evaluate(_ body: String, frame id: String? = nil, arguments: [String: Any] = [:], page: Bool = false) async throws -> Any {
        guard let webView else { throw PluginFailure(message: "browser closed") }
        let frame: WKFrameInfo?
        if let id {
            guard let found = frames[id] else { throw PluginFailure(message: "unknown frame; list frames again") }
            frame = found
            // A WKFrameInfo may outlive the document. Never reuse a ref in a new document.
            let current: Any?
            do {
                current = try await webView.callAsyncJavaScript("return globalThis.__tilrBrowser?.id", arguments: [:], in: frame, contentWorld: Self.world)
            } catch {
                // The frame is gone (WebKit has no public subframe-removal signal besides pagehide).
                frames.removeValue(forKey: id)
                throw PluginFailure(message: "frame is gone; list frames again")
            }
            guard current as? String == id else {
                frames.removeValue(forKey: id)
                throw PluginFailure(message: "stale frame; list frames again")
            }
        } else { frame = nil }
        guard timeout.isFinite, timeout > 0 else { throw PluginFailure(message: "browser.automation_timeout must be positive") }
        let source = """
        let timer;
        try {
          const value = await Promise.race([(async () => {\n\(body)\n})(), new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('browser JavaScript timed out')), \(timeout * 1000));
          })]);
          return JSON.stringify(value === undefined ? null : value);
        } finally { clearTimeout(timer); }
        """
        try Task.checkCancellation()
        let result = try await webView.callAsyncJavaScript(source, arguments: arguments, in: frame, contentWorld: page ? .page : Self.world)
        try Task.checkCancellation()
        guard let text = result as? String else { return NSNull() }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    @MainActor
    func frameList() async -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (id, frame) in Array(frames) {
            if let info = try? await evaluate("return {id: __tilrBrowser.id, url: location.href, title: document.title}", frame: id) as? [String: Any] {
                var row = info
                row["main"] = frame.isMainFrame
                result.append(row)
            } else { frames.removeValue(forKey: id) }
        }
        return result.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }

    /// Resolve inside each native frame, including cross-origin frames. Parent documents map
    /// WindowProxy identities to iframe elements without reading a child's DOM.
    @MainActor
    func point(_ request: [String: Any]) async throws -> NSPoint {
        if let x = request["x"] as? Double, let y = request["y"] as? Double {
            guard request["frame"] == nil else { throw PluginFailure(message: "x/y use main viewport coordinates; omit frame") }
            return NSPoint(x: x, y: y)
        }
        let frame = request["frame"] as? String
        guard var value = try await evaluate("return __tilrBrowser.point(target)", frame: frame,
                                            arguments: ["target": request]) as? [String: Any] else {
            throw PluginFailure(message: "element has no point")
        }
        var child = frame
        var visited = Set<String>()
        while let id = child, frames[id]?.isMainFrame != true {
            guard visited.insert(id).inserted else { throw PluginFailure(message: "iframe parent cycle") }
            var mapped: [String: Any]?
            for parent in Array(frames.keys) where parent != id {
                if let row = try? await evaluate("return __tilrBrowser.mapChild(child, point)", frame: parent,
                                                arguments: ["child": id, "point": value]) as? [String: Any] {
                    mapped = row
                    child = parent
                    break
                }
            }
            guard let mapped else { throw PluginFailure(message: "iframe is detached, obscured, or not ready; refresh frames") }
            value = mapped
        }
        guard let x = value["x"] as? Double, let y = value["y"] as? Double else {
            throw PluginFailure(message: "element has no visible point")
        }
        return NSPoint(x: x, y: y)
    }

    @MainActor
    func input(_ action: String, at point: NSPoint, request: [String: Any]) async throws {
        guard let webView, !webView.isHiddenOrHasHiddenAncestor, let window = webView.window,
              let content = window.contentView, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < webView.bounds.width, point.y < webView.bounds.height else {
            throw PluginFailure(message: "browser point is outside a visible viewport")
        }
        let local = NSPoint(x: point.x, y: webView.isFlipped ? point.y : webView.bounds.height - point.y)
        let location = webView.convert(local, to: nil)
        let contentPoint = content.convert(location, from: nil)
        guard let hit = content.hitTest(contentPoint), hit === webView || hit.isDescendant(of: webView) else {
            throw PluginFailure(message: "browser point is covered by another window")
        }
        guard inputInterval.isFinite, inputInterval > 0, inputInterval <= timeout else {
            throw PluginFailure(message: "browser.automation_input_interval must be positive and <= automation_timeout")
        }
        try Task.checkCancellation()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        // Activation reaches the WebContent process asynchronously. AppKit can otherwise
        // consume the first click solely to activate an inactive app/window.
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if NSApp.isActive, window.isKeyWindow,
               try await evaluate("return document.hasFocus()", page: true) as? Bool == true { break }
            guard Date() < deadline else { throw PluginFailure(message: "browser did not acquire input focus") }
            try await Task.sleep(nanoseconds: UInt64(inputInterval * 1_000_000_000))
        }
        // Focusing can change layout; do not send input to a newly covered native view.
        guard let currentHit = content.hitTest(contentPoint), currentHit === webView || currentHit.isDescendant(of: webView) else {
            throw PluginFailure(message: "browser point became covered while focusing")
        }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: action == "click" ? 1 : 0, pressure: 0) else {
                throw PluginFailure(message: "cannot create mouse event")
            }
            return e
        }
        try Task.checkCancellation()
        if action == "hover" {
            // WKWebView does not forward mouseMoved to its implementation via NSResponder.
            let move = NSSelectorFromString("_simulateMouseMove:")
            guard privateInput, webView.responds(to: move) else {
                throw PluginFailure(message: "native hover unavailable on this WebKit")
            }
            webView.perform(move, with: try event(.mouseMoved))
        }
        else {
            window.makeFirstResponder(hit)
            window.sendEvent(try event(.leftMouseDown))
            window.sendEvent(try event(.leftMouseUp))
        }
    }

    static let script = #"""
    (() => {
      const id = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16).padStart(8, '0')).join('');
      // Refs live from one snapshot to the next; next keeps counting so an older ref never resolves.
      let refs = new Map(), ids = new WeakMap();
      const children = new Map();
      let next = 0;
      function ref(el) { if (!ids.has(el)) { const r = `${id}:${++next}`; ids.set(el, r); refs.set(r, el); } return ids.get(el); }
      function element(t) {
        let el;
        if (t.ref) el = refs.get(t.ref);
        else if (t.selector) { const all = document.querySelectorAll(t.selector); if (all.length !== 1) throw Error(`selector matched ${all.length} elements`); el = all[0]; }
        else el = document.scrollingElement;
        if (!el?.isConnected) throw Error('stale or unknown ref; take a new snapshot');
        return el;
      }
      function visiblePoint(el) {
        el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
        const r = el.getBoundingClientRect();
        const x = (Math.max(0, r.left) + Math.min(innerWidth, r.right)) / 2;
        const y = (Math.max(0, r.top) + Math.min(innerHeight, r.bottom)) / 2;
        const hit = document.elementFromPoint(x,y);
        if (!r.width || !r.height || !(hit === el || el.contains(hit))) throw Error('element is hidden or covered');
        return {x,y};
      }
      globalThis.__tilrBrowser = {
        id,
        snapshot() {
          refs = new Map(); ids = new WeakMap();
          return {url: location.href, title: document.title, text: document.body?.innerText ?? '',
            elements: [...document.querySelectorAll('a,button,input,textarea,select,[role],[contenteditable],iframe,frame')].map(el => {
              const r = el.getBoundingClientRect();
              return {ref: ref(el), tag: el.localName, role: el.getAttribute('role'), name: el.getAttribute('aria-label') || el.innerText || el.getAttribute('title') || el.getAttribute('placeholder') || '',
                value: el.value ?? null, disabled: !!el.disabled, rect: {x:r.x,y:r.y,width:r.width,height:r.height}};
            })};
        },
        point(t) { return t.ref || t.selector ? visiblePoint(element(t)) : {x:innerWidth/2,y:innerHeight/2}; },
        scroll(t) {
          const dx=t.deltaX ?? 0, dy=t.deltaY ?? 0;
          if (!Number.isFinite(dx) || !Number.isFinite(dy)) throw Error('scroll deltas must be finite numbers');
          let el;
          if (t.ref || t.selector) el=element(t);
          else if (t.x !== undefined || t.y !== undefined) {
            if (!Number.isFinite(t.x) || !Number.isFinite(t.y)) throw Error('x and y must be finite numbers');
            el=document.elementFromPoint(t.x,t.y);
            if (!el) throw Error('scroll point is outside the viewport');
            while (el !== document.scrollingElement) {
              const style=getComputedStyle(el);
              if ((dy && el.scrollHeight>el.clientHeight && /auto|scroll/.test(style.overflowY)) ||
                  (dx && el.scrollWidth>el.clientWidth && /auto|scroll/.test(style.overflowX))) break;
              el=el.parentElement ?? document.scrollingElement;
            }
          } else el=document.scrollingElement;
          if (!el) throw Error('no scrollable document');
          const before={x:el.scrollLeft,y:el.scrollTop};
          el.scrollBy({left:dx,top:dy,behavior:'instant'});
          return {before,after:{x:el.scrollLeft,y:el.scrollTop},method:'dom'};
        },
        mapChild(child,p) {
          const el = children.get(child);
          if (!el?.isConnected) return null;
          visiblePoint(el);
          // Axis-aligned frames only: rotations/perspective need a full transform mapping.
          for (let a=el; a; a=a.parentElement) {
            const s=getComputedStyle(a); if (s.transform !== 'none' || s.perspective !== 'none' || (s.zoom && Number(s.zoom) !== 1 && s.zoom !== 'normal')) throw Error('transformed iframe cannot receive native input');
          }
          const r=el.getBoundingClientRect(), x=r.x+el.clientLeft+p.x, y=r.y+el.clientTop+p.y;
          if (p.x<0 || p.y<0 || p.x>=el.clientWidth || p.y>=el.clientHeight || document.elementFromPoint(x,y)!==el) throw Error('iframe point is clipped or covered');
          return {x,y};
        }
      };
      addEventListener('message', event => {
        if (typeof event.data?.tilrBrowserFrame !== 'string') return;
        for (const el of document.querySelectorAll('iframe,frame')) if (el.contentWindow === event.source) children.set(event.data.tilrBrowserFrame, el);
      });
      webkit.messageHandlers.tilrBrowserFrame.postMessage(id);
      function announce() { if (parent !== window) parent.postMessage({tilrBrowserFrame:id}, '*'); }
      addEventListener('DOMContentLoaded', announce);
      addEventListener('pageshow', event => {
        if (event.persisted) webkit.messageHandlers.tilrBrowserFrame.postMessage(id);
        announce();
      });
      addEventListener('pagehide', () => webkit.messageHandlers.tilrBrowserFrame.postMessage({gone: id}));
    })();
    """#
}

extension WebViewHost {
    @MainActor
    func browserCommand(_ request: [String: Any]) async throws -> [String: Any] {
        let action = request["action"] as? String ?? "list"
        if action == "list" { return ["browsers": browserList()] }
        guard let id = request["browser"] as? String else { throw PluginFailure(message: "browser id required; call browser list") }
        let view = try browser(id)
        let automation = view.automation
        automation.timeout = settings.automationTimeout
        automation.privateInput = settings.automationPrivateInput
        automation.inputInterval = settings.automationInputInterval
        let frame = request["frame"] as? String
        switch action {
        case "frames": return ["frames": await automation.frameList()]
        case "snapshot": return ["value": try await automation.evaluate("return __tilrBrowser.snapshot()", frame: frame)]
        case "evaluate":
            guard let js = request["js"] as? String else { throw PluginFailure(message: "js must be an async function body; use return") }
            return ["value": try await automation.evaluate(js, frame: frame, arguments: ["args": request["args"] ?? NSNull()], page: true)]
        case "navigate":
            guard let url = request["url"] as? String, let parsed = URL(string: url),
                  ["https", "http", "about", "file", "data"].contains(parsed.scheme?.lowercased() ?? "") else { throw PluginFailure(message: "invalid browser URL") }
            view.load(url)
            return ["navigating": url]
        case "scroll":
            return ["value": try await automation.evaluate("return __tilrBrowser.scroll(target)", frame: frame,
                                                          arguments: ["target": request])]
        case "click", "hover":
            let point = try await automation.point(request)
            try await automation.input(action, at: point, request: request)
            return ["dispatched": action, "x": point.x, "y": point.y]
        default: throw PluginFailure(message: "unknown browser action: \(action)")
        }
    }
}
