import AppKit
import WebKit

// Only the bridge's owning-page references are stubbed; WebKit and ConfigFiles are production.
enum Config { static var dir = FileManager.default.temporaryDirectory }
final class Tab {
    struct App { let origin = URL(string: "tilr://config-test")! }
    let app = App()
    let webView: WKWebView
    init(_ webView: WKWebView) { self.webView = webView }
}

final class Page: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    var loaded: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let data = Data("<!doctype html><html><body>Config fixture</body></html>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                            expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    @MainActor func load(_ view: WKWebView, url: URL) async {
        await withCheckedContinuation { done in loaded = done; view.load(URLRequest(url: url)) }
    }
}

@main struct ConfigBridgeTests {
    @MainActor static func evaluate(_ view: WKWebView, _ source: String) async throws -> Any {
        try await withCheckedThrowingContinuation { done in
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                done.resume(with: result)
            }
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        Config.dir = root
        let page = Page()
        let bridge = ConfigBridge()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(page, forURLScheme: "tilr")
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: ConfigBridge.name)
        let view = WKWebView(frame: .zero, configuration: configuration)
        let tab = Tab(view)
        bridge.tab = tab
        view.navigationDelegate = page
        await page.load(view, url: tab.app.origin)
        let result = try await evaluate(view, """
            const config = webkit.messageHandlers.tilrConfig;
            const write = await config.postMessage({op:'write', name:'test.yml', text:'a: 1'});
            const read = await config.postMessage({op:'read', name:'test.yml'});
            const missing = await config.postMessage({op:'read', name:'missing.yml'});
            const denied = await config.postMessage({op:'write', name:'config.yml', text:'no'}).then(() => '', e => String(e));
            const path = await config.postMessage({op:'read', name:'../x'}).then(() => '', e => String(e));
            return {ok:write.ok, read, missing:missing === null, denied, path};
            """) as! [String: Any]
        precondition(result["ok"] as? Bool == true)
        precondition(result["read"] as? String == "a: 1")
        precondition(result["missing"] as? Bool == true)
        precondition((result["denied"] as? String)?.contains("read-only") == true)
        precondition((result["path"] as? String)?.contains("filename") == true)
        let text = try String(contentsOf: root.appendingPathComponent("test.yml"), encoding: .utf8)
        precondition(text == "a: 1")
        let subframe = try await evaluate(view, """
            return await new Promise(resolve => {
                window.addEventListener('message', event => resolve(event.data), {once:true});
                const frame = document.createElement('iframe');
                frame.srcdoc = `<script>webkit.messageHandlers.tilrConfig.postMessage({op:'read',name:'test.yml'}).then(() => parent.postMessage('accepted','*'), e => parent.postMessage(String(e),'*'))</script>`;
                document.body.appendChild(frame);
            });
            """) as? String
        precondition(subframe?.contains("restricted") == true)
        let watchStarted = Date()
        var watcher: FolderWatcher?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            watcher = FolderWatcher(root, latency: 0.2) { paths in
                if ConfigFiles(directory: root).changedNames(paths).contains("external.yml") {
                    watcher = nil
                    done.resume()
                }
            }
            // Register first, then drive a real editor-style atomic save, waiting on its event.
            try! "external".write(to: root.appendingPathComponent("external.yml"), atomically: true, encoding: .utf8)
        }
        precondition(Date().timeIntervalSince(watchStarted) < 1, "Default config watch must report within one second")
        // The same handler remains installed on a different top-level origin.
        await page.load(view, url: URL(string: "tilr://foreign")!)
        let error = try await evaluate(view, """
            return await webkit.messageHandlers.tilrConfig.postMessage({op:'read',name:'test.yml'}).then(() => '', e => String(e));
            """) as? String
        precondition(error?.contains("restricted") == true)
        withExtendedLifetime(tab) {}
        configuration.userContentController.removeScriptMessageHandler(forName: ConfigBridge.name, contentWorld: .page)
        print("trusted config WebKit bridge tests passed")
    }
}
