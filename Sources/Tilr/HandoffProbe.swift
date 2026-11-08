import AppKit
import WebKit

extension AppDelegate {
    /// Real WKWebViews and the production relay. A held ack drives expiration and closure
    /// deterministically; no clock delay or animation settling is used as synchronization.
    @MainActor
    func probeHandoff() async {
        let probe = ProbeCheck("probe-handoff", cleanup: { Instance.terminating() })
        guard let first = shells.first, let source = first.current else { probe.fail("handoff: no source") }
        let second = openWindow(source.app)
        guard let target = second.current else { probe.fail("handoff: no target") }
        defer { if shells.contains(where: { $0 === second }) { second.window.close() } }
        func js(_ tab: Tab, _ body: String, _ args: [String: Any] = [:]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                tab.webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                    continuation.resume(with: result)
                }
            }
        }
        do {
            for (role, tab) in [("source", source), ("target", target)] {
                await tab.firstLoad(within: config.control.loadTimeout)
                guard tab.isLoaded, tab.loadError == nil else {
                    let reason = tab.loadError.map { "navigation failed: \($0)" }
                        ?? (tab.loadEnded ? "navigation failed" : "navigation timed out")
                    throw NSError(domain: "HandoffProbe", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "\(role): \(reason)"])
                }
                _ = try await js(tab, """
                    // Navigation completion does not await module top-level awaits.
                    // Subscribe and check in one JS turn so publication cannot be missed.
                    await new Promise((resolve, reject) => {
                      const finish = error => {
                        clearTimeout(timer);
                        window.removeEventListener('tilr:ready', ready);
                        if (error) reject(error); else resolve();
                      };
                      const ready = () => {
                        if (!window.tilr) return;
                        window.removeEventListener('tilr:ready', ready);
                        window.tilr.root.inject(['layout'], () => finish());
                      };
                      const timer = setTimeout(() => finish(new Error(role + ': runtime/layout readiness timed out')), timeout);
                      window.addEventListener('tilr:ready', ready);
                      ready();
                    });
                    return true;
                    """, ["role": role, "timeout": config.control.loadTimeout * 1000])
            }
            print("handoff: checking host discovery")
            let listed = try await js(source, """
                const list = await webkit.messageHandlers.tilrHandoff.postMessage({op:'shell.list'});
                return list.windows.some(row => row.host === to) && list.windows.some(row => row.host === window.__tilrHost.host);
                """, ["to": second.hostID.uuidString]) as? Bool
            probe(listed == true, "handoff picker could not list native hosts through Control socket")
            for tab in [source, target] {
                _ = try await js(tab, """
                    window.tilr.root.get('windows').register('handoff-probe', {
                      open: 'never', title: 'Handoff probe', mount(host, win) {
                        const header = document.createElement('div'); header.setAttribute('data-window-drag', ''); header.textContent = 'Probe'; host.append(header);
                        const text = document.createElement('div'); text.textContent = win.config.content;
                        text.dataset.handoffProbe = win.id; host.append(text); return () => text.remove();
                      }
                    });
                    return true;
                    """)
            }
            guard let id = try await js(source, "return window.tilr.root.get('layout').open({type:'handoff-probe',config:{content:'portable content',pane:'stable-session'}})") as? String else {
                probe.fail("handoff: no probe id")
            }
            _ = try await js(source, "return await window.tilr.root.get('layout').handoff(id, to)", ["id": id, "to": second.hostID.uuidString])
            let gone = try await js(source, "return !window.tilr.root.get('layout').get(id)", ["id": id]) as? Bool
            let restored = try await js(target, """
                const row = window.tilr.root.get('layout').get(id);
                return row?.id === id && row.config.content === 'portable content' && row.config.pane === 'stable-session';
                """, ["id": id]) as? Bool
            probe(gone == true && restored == true, "handoff did not preserve identity and content")
            _ = try await js(target, "return await window.tilr.root.get('layout').handoff(id, to)", ["id": id, "to": first.hostID.uuidString])
            let invalid = try await js(source, """
                try { await window.tilr.root.get('layout').handoff(id, 'missing'); return false; }
                catch { return !!window.tilr.root.get('layout').get(id); }
                """, ["id": id]) as? Bool
            probe(invalid == true, "invalid handoff lost source")

            print("handoff: checking native pointer takeover")
            // Drive production pointer transitions and hold only the asynchronous snapshot reply.
            // A held capture makes release/cancel ordering deterministic without clock delays.
            first.set(.window); second.set(.window)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
            first.window.setFrame(NSRect(x: screen.minX + 20, y: screen.minY + 40, width: 500, height: 500), display: true)
            second.window.setFrame(NSRect(x: screen.minX + 550, y: screen.minY + 40, width: 500, height: 500), display: true)
            second.window.orderFrontRegardless()
            typealias HeldCapture = (WKWebView, WKSnapshotConfiguration, (NSImage?, Error?) -> Void)
            let capturePanel = handoffs.capturePanel
            defer { handoffs.capturePanel = capturePanel; handoffs.cancelPointer() }
            func armPointer() async throws -> HeldCapture {
                _ = try await js(source, """
                    const layout = window.tilr.root.get('layout');
                    layout.float(id, {x:50,y:50,width:300,height:240});
                    await new Promise(resolve => {
                      const ready = () => {
                        const element = document.querySelector('[data-window="' + id + '"]');
                        return element?.dataset.mode === 'float' && element.style.left === '50px' && element.style.width === '300px';
                      };
                      if (ready()) { resolve(); return; }
                      const observer = new MutationObserver(() => { if (ready()) { observer.disconnect(); resolve(); } });
                      observer.observe(document.body,{subtree:true,childList:true,attributes:true});
                    });
                    const header = document.querySelector('[data-window="' + id + '"] [data-window-drag]');
                    const box = header.getBoundingClientRect();
                    header.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,button:0,clientX:box.x+20,clientY:box.y+8}));
                    window.__pointerDone = new Promise(resolve => {
                      const check = () => { if (!layout.get(id)) { observer.disconnect(); resolve(true); } };
                      const observer = new MutationObserver(check); observer.observe(document.body,{subtree:true,childList:true}); check();
                    });
                    await webkit.messageHandlers.tilrHandoff.postMessage({op:'shell.list'});
                    return true;
                    """, ["id": id])
                handoffs.pointerMoved(to: NSPoint(x: first.window.frame.midX, y: first.window.frame.midY))
                probe(handoffs.pointerStatus?.taken == false, "inside-frame movement took native ownership")
                return await withCheckedContinuation { continuation in
                    handoffs.capturePanel = { view, config, complete in continuation.resume(returning: (view, config, complete)) }
                    handoffs.pointerMoved(to: NSPoint(x: first.window.frame.maxX + 10, y: first.window.frame.midY))
                }
            }
            let cancelledCapture = try await armPointer()
            handoffs.cancelPointer()
            cancelledCapture.2(NSImage(size: NSSize(width: 300, height: 240)), nil)
            probe(handoffs.pointerStatus == nil, "late snapshot resurrected a cancelled pointer session")
            func sourceUsable() async throws -> Bool {
                return (try await js(source, """
                const layout = window.tilr.root.get('layout');
                const usable = () => layout.get(id) && !layout.frozen(id);
                if (!usable()) await new Promise(resolve => {
                  const observer = new MutationObserver(() => { if (usable()) { observer.disconnect(); resolve(); } });
                  observer.observe(document.body,{subtree:true,attributes:true});
                });
                return usable();
                """, ["id": id]) as? Bool) == true
            }
            probe(try await sourceUsable(), "cancelled native drag lost or froze its source")
            let visibleCapture = try await armPointer()
            // A previous gesture's completion cannot change the new gesture.
            cancelledCapture.2(NSImage(size: NSSize(width: 300, height: 240)), nil)
            probe(handoffs.pointerStatus?.ready == false, "stale capture changed a newer gesture")
            let visibleSnapshot: Bool = await withCheckedContinuation { continuation in
                capturePanel(visibleCapture.0, visibleCapture.1) { image, error in
                    visibleCapture.2(image, error)
                    continuation.resume(returning: image != nil && error == nil)
                }
            }
            probe(visibleSnapshot && handoffs.pointerStatus?.showing == true, "snapshot did not create a floating panel")
            handoffs.pointerMoved(to: NSPoint(x: first.window.frame.maxX + 50, y: first.window.frame.midY))
            handoffs.pointerReleased(at: NSPoint(x: -10000, y: -10000))
            probe(handoffs.pointerStatus == nil, "outside release retained native tracking")
            probe(try await sourceUsable(), "outside release lost or froze its source")
            let releasedCapture = try await armPointer()
            let targetPoint = try await js(target, "const box=document.querySelector('.tilr-canvas').getBoundingClientRect(); return {x:box.x+70,y:box.y+90};") as? [String: Double]
            guard let targetPoint, let tx = targetPoint["x"], let ty = targetPoint["y"] else { probe.fail("no target canvas") }
            let local = NSPoint(x: tx * target.webView.pageZoom,
                                y: target.webView.isFlipped ? ty * target.webView.pageZoom : target.webView.bounds.height - ty * target.webView.pageZoom)
            let release = second.window.convertPoint(toScreen: target.webView.convert(local, to: nil))
            handoffs.pointerReleased(at: release)
            probe(handoffs.pointerStatus?.taken == true && handoffs.pointerStatus?.showing == false, "early release did not retain pending capture")
            let captured: Bool = await withCheckedContinuation { continuation in
                capturePanel(releasedCapture.0, releasedCapture.1) { image, error in
                    releasedCapture.2(image, error)
                    continuation.resume(returning: image != nil && error == nil)
                }
            }
            probe(captured, "real panel snapshot failed")
            let pointerGone = try await js(source, "return await window.__pointerDone") as? Bool
            let pointerPositioned = try await js(target, "const row=window.tilr.root.get('layout').get(id);return row?.rect.x===70 && row?.rect.y===90;", ["id": id]) as? Bool
            probe(pointerGone == true && pointerPositioned == true && handoffs.pointerStatus == nil,
                  "native pointer handoff lost identity, coordinates or cleanup")
            handoffs.capturePanel = capturePanel
            _ = try await js(target, "return await window.tilr.root.get('layout').handoff(id, to)", ["id": id, "to": first.hostID.uuidString])

            // Exercise the drag ticket through the real native relay, with only WebKit's text fallback.
            let dragText = try await js(source, """
                const layout = window.tilr.root.get('layout'); layout.float(id);
                const header = document.querySelector('[data-window="' + id + '"] [data-window-drag]');
                header.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true, button:0}));
                const dataTransfer = new DataTransfer();
                header.dispatchEvent(new DragEvent('dragstart', {bubbles:true, cancelable:true, dataTransfer}));
                window.__dragDone = new Promise(resolve => {
                  const observer = new MutationObserver(() => {
                    if (!layout.get(id)) { observer.disconnect(); resolve(true); }
                  });
                  observer.observe(document.body, {subtree:true, childList:true});
                });
                await webkit.messageHandlers.tilrHandoff.postMessage({op:'shell.list'});
                return dataTransfer.getData('text/plain');
                """, ["id": id]) as? String
            guard let dragText, dragText.hasPrefix("tilr-window:") else { probe.fail("drag did not encode a ticket") }
            _ = try await js(target, """
                const canvas = document.querySelector('.tilr-canvas'); const box = canvas.getBoundingClientRect();
                const dataTransfer = new DataTransfer(); dataTransfer.setData('text/plain', text);
                canvas.dispatchEvent(new DragEvent('drop', {bubbles:true, cancelable:true, dataTransfer, clientX:box.x+70, clientY:box.y+90}));
                return true;
                """, ["text": dragText])
            let dragGone = try await js(source, "return await window.__dragDone") as? Bool
            let positioned = try await js(target, """
                const layout = window.tilr.root.get('layout');
                const matches = () => { const row = layout.get(id); return row?.rect.x === 70 && row.rect.y === 90; };
                if (matches()) return true;
                return await new Promise(resolve => {
                  const observer = new MutationObserver(() => { if (matches()) { observer.disconnect(); resolve(true); } });
                  observer.observe(document.body, {subtree:true, childList:true, attributes:true});
                });
                """, ["id": id]) as? Bool
            probe(dragGone == true && positioned == true, "drag handoff lost source or drop coordinates")
            _ = try await js(target, "return await window.tilr.root.get('layout').handoff(id, to)", ["id": id, "to": first.hostID.uuidString])

            for closes in [false, true] {
                _ = try await js(target, """
                    const handler = webkit.messageHandlers.tilrHandoff;
                    const post = handler.postMessage.bind(handler);
                    window.__handoffSeen = new Promise(resolve => {
                      handler.postMessage = body => {
                        if (body.op === 'handoff.ack') {
                          window.__handoffHeld = body; resolve(body.ticket); return new Promise(() => {});
                        }
                        return post(body);
                      };
                    });
                    window.__handoffPost = post;
                    return true;
                    """)
                let moving = Task { @MainActor in
                    try await js(source, """
                        try { await window.tilr.root.get('layout').handoff(id, to); return 'committed'; }
                        catch (error) { return String(error); }
                        """, ["id": id, "to": second.hostID.uuidString])
                }
                guard let ticket = try await js(target, "return await window.__handoffSeen") as? String else {
                    probe.fail("handoff: target never received offer")
                }
                if closes { second.window.close() }
                else { handoffs.cancel(ticket, reason: "Handoff timed out") }
                let failure = try await moving.value as? String
                probe(failure?.contains(closes ? "closed" : "timed out") == true, "handoff cancellation did not reject")
                let alive = try await js(source, "return !!window.tilr.root.get('layout').get(id)", ["id": id]) as? Bool
                probe(alive == true, "handoff rollback lost source")
                if !closes {
                    let cleaned = try await js(target, "return !window.tilr.root.get('layout').get(id)", ["id": id]) as? Bool
                    let late = try await js(target, """
                        try { await window.__handoffPost(window.__handoffHeld); return false; } catch { return true; }
                        """) as? Bool
                    probe(cleaned == true && late == true, "handoff kept provisional window or accepted late ack")
                }
            }
            _ = try await js(source, "window.tilr.root.get('layout').close(id); return true", ["id": id])
            print("layout handoff: real-page move, native pointer snapshot/early release/cancel, drag text fallback/position, identity/content, invalid host, expiration, late ack and closed target: ok")
        } catch { probe.fail("layout handoff probe: \(error)") }
    }
}
