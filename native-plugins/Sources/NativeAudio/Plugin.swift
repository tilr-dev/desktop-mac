import Foundation
import TilrPluginABI

@MainActor
@_cdecl("tilr_plugin_create_v1")
public func createAudioPlugin() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(AudioPlugin()).toOpaque()
}

@MainActor
final class AudioPlugin: NSObject, @preconcurrency TLRNativePlugin {
    let abiVersion = 1
    private let audio = AudioHost()

    func start(host: TLRPluginHost) {
        audio.send = { [weak host] in host?.emit(AudioHost.event, detail: $0) }
        audio.siteFile = { [weak host] in host?.resolveSiteURL($0) }
    }
    func receive(_ message: [String: Any], channel: String) {
        if channel == "audio" { audio.handle(message) }
    }
    func request(_ request: [String: Any], service: String, identifier: String, completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard service == "audio" else {
            completion(nil, NSError(domain: "Tilr.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown service"])); return
        }
        audio.handle(request)
        completion(["accepted": true], nil)
    }
    func cancelRequest(_ identifier: String) {} // Audio control completes synchronously.
    func pageDidNavigate() {} // Players belong to the native session, not the page.
    func configurationDidChange() {}
    func stop() { audio.stopAll() }
}
