import AppKit
import WebKit

extension AppDelegate {
    /// Real WKWebViews and the production relay. A held ack drives expiration and closure
    /// deterministically; no clock delay or animation settling is used as synchronization.
    @MainActor
    func probeHandoff() async {
        guard let first = shells.first, let source = first.current else { preconditionFailure("handoff: no source") }
        let second = openWindow(source.app)
        guard let target = second.current else { preconditionFailure("handoff: no target") }
        defer { if shells.contains(where: { $0 === second }) { second.window.close() } }
        await target.firstLoad(within: config.control.loadTimeout)
        func js(_ tab: Tab, _ body: String, _ args: [String: Any] = [:]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                tab.webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                    continuation.resume(with: result)
                }
            }
        }
        do {
            let listed = try await js(source, """
                const list = await webkit.messageHandlers.tilrHandoff.postMessage({op:'shell.list'});
                return list.windows.some(row => row.host === to) && list.windows.some(row => row.host === window.__tilrHost.host);
                """, ["to": second.hostID.uuidString]) as? Bool
            precondition(listed == true, "handoff picker could not list native hosts through Control socket")
            for tab in [source, target] {
                _ = try await js(tab, """
                    if (!window.tilr) throw new Error('Handoff probe requires a runtime site');
                    await new Promise(resolve => window.tilr.root.inject(['layout'], () => resolve()));
                    window.tilr.root.get('windows').register('handoff-probe', {
                      open: 'never', title: 'Handoff probe', mount(host, win) {
                        const text = document.createElement('div'); text.textContent = win.config.content;
                        text.dataset.handoffProbe = win.id; host.append(text); return () => text.remove();
                      }
                    });
                    return true;
                    """)
            }
            guard let id = try await js(source, "return window.tilr.root.get('layout').open({type:'handoff-probe',config:{content:'portable content',pane:'stable-session'}})") as? String else {
                preconditionFailure("handoff: no probe id")
            }
            _ = try await js(source, "return await window.tilr.root.get('layout').handoff(id, to)", ["id": id, "to": second.hostID.uuidString])
            let gone = try await js(source, "return !window.tilr.root.get('layout').get(id)", ["id": id]) as? Bool
            let restored = try await js(target, """
                const row = window.tilr.root.get('layout').get(id);
                return row?.id === id && row.config.content === 'portable content' && row.config.pane === 'stable-session';
                """, ["id": id]) as? Bool
            precondition(gone == true && restored == true, "handoff did not preserve identity and content")
            _ = try await js(target, "return await window.tilr.root.get('layout').handoff(id, to)", ["id": id, "to": first.hostID.uuidString])
            let invalid = try await js(source, """
                try { await window.tilr.root.get('layout').handoff(id, 'missing'); return false; }
                catch { return !!window.tilr.root.get('layout').get(id); }
                """, ["id": id]) as? Bool
            precondition(invalid == true, "invalid handoff lost source")

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
                    preconditionFailure("handoff: target never received offer")
                }
                if closes { second.window.close() }
                else { handoffs.cancel(ticket, reason: "Handoff timed out") }
                let failure = try await moving.value as? String
                precondition(failure?.contains(closes ? "closed" : "timed out") == true, "handoff cancellation did not reject")
                let alive = try await js(source, "return !!window.tilr.root.get('layout').get(id)", ["id": id]) as? Bool
                precondition(alive == true, "handoff rollback lost source")
                if !closes {
                    let cleaned = try await js(target, "return !window.tilr.root.get('layout').get(id)", ["id": id]) as? Bool
                    let late = try await js(target, """
                        try { await window.__handoffPost(window.__handoffHeld); return false; } catch { return true; }
                        """) as? Bool
                    precondition(cleaned == true && late == true, "handoff kept provisional window or accepted late ack")
                }
            }
            _ = try await js(source, "window.tilr.root.get('layout').close(id); return true", ["id": id])
            print("layout handoff: real-page move, identity/content, invalid host, expiration, late ack and closed target: ok")
        } catch { preconditionFailure("layout handoff probe: \(error)") }
    }
}
