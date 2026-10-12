import AppKit
import WebKit
import UniformTypeIdentifiers

/// Demand-driven samples for the optional Performance plugin. No native timer or background
/// task: each request reads once. Disabling the plugin drops the sampler's CPU baselines.
/// Messages: `'sample'`, `'reset'`, `{ op: 'save' | 'open' }` (recording files), and
/// `{ type: 'footprint' | 'squeeze' | 'inspector' }` (Memory.swift: memory categories,
/// org.WebKit.lowMemory with before/after, Web Inspector).
final class PerformanceBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "tilrPerformance"
    weak var tab: Tab?
    private var sampler = ProcessSampler()
    private var filePanel: NSSavePanel?

    func reset() { sampler = ProcessSampler(); filePanel?.cancel(nil); filePanel = nil }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab, message.frameInfo.isMainFrame, message.webView === tab.webView,
              message.frameInfo.securityOrigin.protocol == "tilr",
              message.frameInfo.securityOrigin.host == tab.app.origin.host else {
            replyHandler(nil, "Performance access is restricted to the Tilr app page.")
            return
        }
        if let request = message.body as? [String: Any], let op = request["op"] as? String,
           op == "save" || op == "open" {
            guard filePanel == nil else { replyHandler(nil, "A recording file dialog is already open."); return }
            if op == "save" {
                guard let contents = request["contents"] as? String, let name = request["name"] as? String,
                      let data = contents.data(using: .utf8) else { replyHandler(nil, "Missing recording contents."); return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent
                filePanel = panel
                let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    self?.filePanel = nil
                    guard response == .OK, let url = panel.url else { replyHandler(NSNull(), nil); return }
                    do { try data.write(to: url, options: .atomic); replyHandler(NSNull(), nil) }
                    catch { replyHandler(nil, error.localizedDescription) }
                }
                if let window = tab.webView.window { panel.beginSheetModal(for: window, completionHandler: complete) }
                else { panel.begin(completionHandler: complete) }
            } else {
                guard let limit = request["maxBytes"] as? Int, limit > 0, limit < Int.max else { replyHandler(nil, "Missing recording size limit."); return }
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.json]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                filePanel = panel
                let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    self?.filePanel = nil
                    guard response == .OK, let url = panel.url else { replyHandler(NSNull(), nil); return }
                    do {
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        let data = try file.read(upToCount: limit + 1) ?? Data()
                        guard data.count <= limit else { replyHandler(nil, "Recording exceeds the allowed size."); return }
                        guard let contents = String(data: data, encoding: .utf8) else { replyHandler(nil, "Recording is not UTF-8 JSON."); return }
                        replyHandler(contents, nil)
                    }
                    catch { replyHandler(nil, error.localizedDescription) }
                }
                if let window = tab.webView.window { panel.beginSheetModal(for: window, completionHandler: complete) }
                else { panel.begin(completionHandler: complete) }
            }
            return
        }
        if let request = message.body as? [String: Any], let type = request["type"] as? String {
            switch type {
            case "footprint": Memory.footprint(Memory.targets(tab)) { replyHandler($0, nil) }
            case "squeeze": Memory.squeeze(tab) { replyHandler($0, nil) }
            case "inspector": replyHandler(Memory.inspector(tab), nil)
            default: replyHandler(nil, "Unknown performance request.")
            }
            return
        }
        if message.body as? String == "reset" { reset(); replyHandler([], nil); return }
        guard message.body as? String == "sample" else { replyHandler(nil, "Unknown performance request."); return }
        // Native providers mount their views beneath the page's container. A process shared by
        // multiple views is read only once and its scope explicitly lists those views.
        let pages = Memory.webContent(tab)
        let now = Date().timeIntervalSince1970 * 1000
        var result: [[String: Any]] = []
        for page in pages {
            if let sample = sampler.read(page.pid, name: "WebContent", at: now) { result.append(row(sample, scope: page.scope)) }
        }
        if let sample = sampler.read(getpid(), name: "Tilr", at: now) { result.append(row(sample, scope: "app")) }
        sampler.retainPIDs(Set(pages.map(\.pid)).union([getpid()]))
        replyHandler(result, nil)
    }

    private func row(_ sample: ProcessSampler.Sample, scope: String) -> [String: Any] {
        ["pid": Int(sample.pid), "name": sample.name, "scope": scope,
         "cpu": sample.cpuReady ? sample.cpu as Any : NSNull(),
         "cpuSeconds": sample.cpuSeconds, "memory": sample.rss]
    }
}
