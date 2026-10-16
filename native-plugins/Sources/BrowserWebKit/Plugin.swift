import Foundation
import TilrPluginABI

@_cdecl("tilr_plugin_create_v1")
public func createBrowserPlugin() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(BrowserPlugin()).toOpaque()
}

final class BrowserPlugin: NSObject, TLRNativePlugin {
    let abiVersion = 1
    private weak var host: TLRPluginHost?
    private var views: WebViewHost?
    private var requests: [String: Task<Void, Never>] = [:]

    func start(host: TLRPluginHost) {
        self.host = host
        configurationDidChange()
    }

    func configurationDidChange() {
        guard let host else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: host.configuration["browser"] ?? [:])
            let settings = try JSONDecoder().decode(BrowserSettings.self, from: data)
            guard settings.tunnelChunk > 0, settings.automationTimeout.isFinite, settings.automationTimeout > 0,
                  settings.automationInputInterval > 0, settings.automationInputInterval <= settings.automationTimeout,
                  ["all", "main"].contains(settings.automationFrames),
                  settings.liveResizeInterval.isFinite, settings.liveResizeInterval >= 0,
                  settings.progressInterval.isFinite, settings.progressInterval >= 0,
                  settings.adoptGrace.isFinite, settings.adoptGrace >= 0,
                  settings.discardAfter.isFinite, settings.discardAfter >= 0 else {
                throw PluginFailure(message: "invalid browser configuration")
            }
            if let views { views.settings = settings }
            else { views = WebViewHost(settings: settings); views?.host = host }
        } catch { print("browser-webkit configuration:", error.localizedDescription) }
    }

    func receive(_ message: [String: Any], channel: String) {
        guard channel == "webviews" else { return }
        views?.receive(message)
    }

    func request(_ request: [String: Any], service: String, identifier: String, completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard service == "browser", let views else {
            completion(nil, PluginFailure(message: "browser-webkit is unavailable")); return
        }
        requests[identifier] = Task { @MainActor [weak self] in
            defer { self?.requests[identifier] = nil }
            do {
                try Task.checkCancellation()
                if request["action"] as? String == "probe" {
                    try await probeBrowserAutomation(settings: views.settings, host: self?.host)
                    completion(["ok": true], nil)
                } else { completion(try await views.browserCommand(request), nil) }
            } catch { completion(nil, error) }
        }
    }

    func cancelRequest(_ identifier: String) { requests.removeValue(forKey: identifier)?.cancel() }
    private func cancelAll() { for task in requests.values { task.cancel() }; requests.removeAll() }
    /// Views with a key wait for the new page to adopt them (`browser.adopt_grace`).
    func pageDidNavigate() { cancelAll(); views?.park() }
    func stop() { cancelAll(); views?.removeAll(); views = nil; host = nil }
}
