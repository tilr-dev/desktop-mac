import AppKit
import Network
import WebKit

/// Transaction owner shared by native hosts. Tickets remain consumed after cancellation.
final class HandoffCoordinator {
    var shells: () -> [Shell] = { [] }
    var socketPath: () -> String = { "" }
    private struct Offered {
        let source: Tab
        let body: [String: Any]
        let reply: (Any?, String?) -> Void
        let timeout: DispatchWorkItem
    }
    private var offered: [String: Offered] = [:]
    private var used = Set<String>()
    private var revisions: [String: Int64] = [:]
    private var pending: [String: Pending] = [:]
    private struct Pending {
        let source: Tab
        let target: Tab
        let targetHost: String
        let position: [String: Any]?
        let reply: (Any?, String?) -> Void
        var acknowledged = false
        var replied = false
        let timeout: DispatchWorkItem
    }

    func receive(_ body: [String: Any], from tab: Tab, reply: @escaping (Any?, String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let op = body["op"] as? String else { reply(nil, "Missing handoff operation"); return }
        if op == "shell.list" {
            let app = tab.app.name
            listHosts { result, error in
                guard let result else { reply(nil, error); return }
                let windows = (result["windows"] as? [[String: Any]] ?? []).filter { $0["app"] as? String == app }
                reply(["windows": windows], nil)
            }
            return
        }
        guard let ticket = body["ticket"] as? String, !ticket.isEmpty else { reply(nil, "Missing handoff ticket"); return }
        if op == "handoff.accept" {
            guard let offer = offered[ticket],
                  let target = shells().first(where: { $0.current === tab }),
                  tab !== offer.source, tab.app.name == offer.source.app.name, tab.isLoaded,
                  let position = body["position"] as? [String: Any],
                  let x = position["x"] as? NSNumber, let y = position["y"] as? NSNumber,
                  CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
                  x.doubleValue.isFinite, y.doubleValue.isFinite else {
                reply(nil, "Invalid drop or unavailable handoff ticket"); return
            }
            offered.removeValue(forKey: ticket)?.timeout.cancel()
            var body = offer.body
            body["targetHost"] = target.hostID.uuidString
            var payload = body["payload"] as? [String: Any] ?? [:]
            payload["position"] = position
            body["payload"] = payload
            receive(body, from: offer.source, reply: offer.reply)
            reply(["accepted": true], nil)
            return
        }
        if op == "handoff.dragend" {
            // A successful drop has already claimed the offer; it must finish independently.
            if let offer = offered[ticket] {
                guard offer.source === tab else { reply(nil, "Handoff belongs to another page"); return }
                cancel(ticket, reason: "Drag cancelled")
            }
            reply(["accepted": true], nil)
            return
        }
        if op == "handoff.offer" {
            guard !used.contains(ticket), offered[ticket] == nil else { reply(nil, "Handoff ticket already used"); return }
            guard let source = shells().first(where: { $0.current === tab }),
                  let payload = body["payload"] as? [String: Any],
                  payload["sourceHost"] as? String == source.hostID.uuidString,
                  let id = payload["id"] as? String, !id.isEmpty,
                  let number = payload["revision"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue, number.doubleValue > 0,
                  number.doubleValue <= 9_007_199_254_740_991 else {
                reply(nil, "Invalid handoff payload or unavailable target host"); return
            }
            guard let host = body["targetHost"] as? String else {
                let timeout = DispatchWorkItem { [weak self] in self?.cancel(ticket, reason: "Handoff timed out") }
                offered[ticket] = Offered(source: tab, body: body, reply: reply, timeout: timeout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
                return
            }
            used.insert(ticket)
            guard let target = shells().first(where: { $0.hostID.uuidString.caseInsensitiveCompare(host) == .orderedSame })?.current,
                  target !== tab, target.app.name == tab.app.name, target.isLoaded else {
                reply(nil, "Invalid handoff payload or unavailable target host"); return
            }
            let revision = number.int64Value
            let key = "\(source.hostID.uuidString):\(id)"
            guard revision > (revisions[key] ?? 0) else { reply(nil, "Stale handoff revision"); return }
            revisions[key] = revision
            let timeout = DispatchWorkItem { [weak self] in self?.cancel(ticket, reason: "Handoff timed out") }
            pending[ticket] = Pending(source: tab, target: target, targetHost: host, position: payload["position"] as? [String: Any], reply: reply, timeout: timeout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            send(target, ["op": "handoff.accept", "ticket": ticket, "payload": payload]) { [weak self] error in
                if let error { self?.cancel(ticket, reason: error) }
            }
            return
        }
        if op == "handoff.cancel", let offer = offered[ticket] {
            guard offer.source === tab else { reply(nil, "Handoff belongs to another page"); return }
            cancel(ticket, reason: "Handoff cancelled")
            reply(["accepted": true], nil)
            return
        }
        guard let item = pending[ticket] else { reply(nil, "Handoff ticket is no longer pending"); return }
        switch op {
        case "handoff.ack":
            guard item.target === tab else { reply(nil, "Handoff acknowledgement from wrong page"); return }
            guard !item.acknowledged else { reply(nil, "Handoff already acknowledged"); return }
            pending[ticket]?.acknowledged = true
            // Source records the commit decision, but closes only when the offer reply resolves.
            send(item.source, ["op": "handoff.commit", "ticket": ticket]) { [weak self] error in
                guard let self, self.pending[ticket] != nil else { reply(nil, "Handoff cancelled"); return }
                if let error { self.cancel(ticket, reason: error); reply(nil, error); return }
                self.send(item.target, ["op": "handoff.commit", "ticket": ticket]) { [weak self] error in
                    guard let self, let active = self.pending[ticket] else { reply(nil, "Handoff cancelled"); return }
                    if let error {
                        self.cancel(ticket, reason: error)
                        reply(nil, error)
                    } else {
                        // Keep the lease until the source has written the shared commit decision.
                        // Navigation in the reply/continuation gap still cancels provisional DOM.
                        self.pending[ticket]?.replied = true
                        var result: [String: Any] = ["ticket": ticket, "targetHost": active.targetHost]
                        if let position = active.position { result["position"] = position }
                        active.reply(result, nil)
                        reply(["accepted": true], nil)
                    }
                }
            }
        case "handoff.finalized":
            guard item.source === tab, item.replied else { reply(nil, "Handoff is not ready to finalize"); return }
            pending.removeValue(forKey: ticket)?.timeout.cancel()
            reply(["accepted": true], nil)
        case "handoff.reject", "handoff.cancel":
            guard item.target === tab || item.source === tab else { reply(nil, "Handoff belongs to another page"); return }
            cancel(ticket, reason: body["error"] as? String ?? "Handoff cancelled")
            reply(["accepted": true], nil)
        default: reply(nil, "Unknown handoff operation")
        }
    }

    /// The production expiration path is also callable by the probe without waiting for time.
    func cancel(_ ticket: String, reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let offer = offered.removeValue(forKey: ticket) {
            used.insert(ticket)
            offer.timeout.cancel()
            send(offer.source, ["op": "handoff.cancel", "ticket": ticket]) { _ in }
            offer.reply(nil, reason)
        }
        guard let item = pending.removeValue(forKey: ticket) else { return }
        item.timeout.cancel()
        send(item.target, ["op": "handoff.cancel", "ticket": ticket]) { _ in }
        send(item.source, ["op": "handoff.cancel", "ticket": ticket]) { _ in }
        if !item.replied { item.reply(nil, reason) }
    }

    func leaving(_ tab: Tab) {
        for (ticket, item) in Array(offered) where item.source === tab {
            cancel(ticket, reason: "Handoff page closed or navigated")
        }
        for (ticket, item) in Array(pending) where item.source === tab || item.target === tab {
            cancel(ticket, reason: "Handoff page closed or navigated")
        }
    }

    private func send(_ tab: Tab, _ body: [String: Any], complete: @escaping (String?) -> Void) {
        guard tab.isLoaded, let json = Tab.json(body) else { complete("Handoff page is unavailable"); return }
        let expected = Site.devURL ?? tab.app.origin
        let view = tab.webView
        view.callAsyncJavaScript("""
            if (location.protocol !== scheme || location.hostname !== host || location.port !== port) throw new Error('Handoff page changed origin');
            \(Tab.dispatch)
            return true;
            """, arguments: ["name": "tilr-handoff", "detail": json, "scheme": (expected.scheme ?? "") + ":",
                              "host": expected.host ?? "", "port": expected.port.map(String.init) ?? ""], in: nil, in: .page) { result in
            guard tab.webView === view else { complete("Handoff page replaced"); return }
            switch result {
            case .success: complete(nil)
            case .failure(let error): complete(error.localizedDescription)
            }
        }
    }

    /// Narrow socket proxy: pages cannot submit arbitrary Control commands.
    private func listHosts(reply: @escaping ([String: Any]?, String?) -> Void) {
        let path = socketPath()
        guard !path.isEmpty else { reply(nil, "Tilr Control is off"); return }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        var finished = false
        var buffer = Data()
        let deadline = DispatchWorkItem {
            if !finished {
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                reply(nil, "Control shell list timed out")
            }
        }
        func finish(_ result: [String: Any]?, _ error: String?) {
            guard !finished else { return }
            finished = true
            deadline.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            reply(result, error)
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { buffer.append(data) }
                if let end = buffer.firstIndex(of: 10) {
                    guard let value = try? JSONSerialization.jsonObject(with: buffer[..<end]) as? [String: Any], value["ok"] as? Bool == true else {
                        finish(nil, "Invalid Control shell list response"); return
                    }
                    finish(value, nil)
                } else if done || error != nil || buffer.count > 1_048_576 { finish(nil, "Control shell list failed") }
                else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data("{\"id\":1,\"cmd\":\"shell\",\"op\":\"list\"}\n".utf8), completion: .contentProcessed { error in
                    if let error { finish(nil, error.localizedDescription) } else { read() }
                })
            case .failed(let error): finish(nil, error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
    }
}

/// Per-page bridge, protected like the paired-plugin bridge; embedded views never receive it.
final class HandoffBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "tilrHandoff"
    weak var tab: Tab?
    weak var coordinator: HandoffCoordinator?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab, let coordinator, message.frameInfo.isMainFrame, message.webView === tab.webView,
              let url = message.frameInfo.request.url else { replyHandler(nil, "Handoff access denied"); return }
        let expected = Site.devURL ?? tab.app.origin
        guard url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port,
              let body = message.body as? [String: Any] else { replyHandler(nil, "Handoff access denied"); return }
        coordinator.receive(body, from: tab, reply: replyHandler)
    }
}
