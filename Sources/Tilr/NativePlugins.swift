import AppKit
import WebKit
import Security
import TilrPluginABI

struct NativePluginFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Signed, independently versioned code packages. Never dlclose Swift/ObjC code:
/// a new installed version takes effect in the next app process.
final class NativePluginLibrary {
    struct Manifest: Decodable {
        let id: String
        let version: String
        let abi: Int
        let minOS: String
        let bridges: [String: String]
        let services: [String]
        let events: [String]
    }
    let manifest: Manifest
    let url: URL
    let thirdParty: Bool
    private let handle: UnsafeMutableRawPointer
    private let create: TLRPluginCreateV1
    private static var loaded: [String: NativePluginLibrary] = [:]
    // Includes disabled modules: a later tab must not load another version's ObjC classes.

    static func open(id: String, directory: URL, allowThirdParty: Bool) throws -> NativePluginLibrary {
        guard validID(id) else { throw NativePluginFailure(message: "invalid native plugin id") }
        if let library = loaded[id] {
            guard allowThirdParty || !library.thirdParty else {
                throw NativePluginFailure(message: "third-party native plugins are disabled; restart Tilr after changing settings")
            }
            return library
        }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let active = folder.appendingPathComponent("active.json")
        let url: URL
        var expectedVersion: String?
        if FileManager.default.fileExists(atPath: active.path) {
            let data = try Data(contentsOf: active)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let version = object["version"], validVersion(version) else {
                throw NativePluginFailure(message: "invalid active version for \(id)")
            }
            url = folder.appendingPathComponent("\(version).tilrplugin")
            expectedVersion = version
        } else if let bundled = Bundle.main.builtInPlugInsURL?.appendingPathComponent("\(id).tilrplugin"),
                  FileManager.default.fileExists(atPath: bundled.path) {
            url = bundled
        } else { throw NativePluginFailure(message: "\(id) is not installed") }
        let library = try NativePluginLibrary(url: url, id: id, expectedVersion: expectedVersion, allowThirdParty: allowThirdParty)
        loaded[id] = library
        return library
    }

    static func validID(_ text: String) -> Bool {
        text.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
    }
    static func validVersion(_ text: String) -> Bool {
        text.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    }

    static func checkPackage(_ url: URL, allowThirdParty: Bool) throws {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Resources/manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard validID(manifest.id) else { throw NativePluginFailure(message: "invalid native plugin id") }
        let library = try NativePluginLibrary(url: url, id: manifest.id, allowThirdParty: allowThirdParty)
        let plugin = try library.make()
        plugin.stop()
        print("native plugin check: \(manifest.id) \(manifest.version) ABI \(plugin.abiVersion)")
    }

    private init(url: URL, id: String, expectedVersion: String? = nil, allowThirdParty: Bool) throws {
        self.url = url
        // Verify the resource seal too: the signed manifest determines all exposed names.
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw NativePluginFailure(message: "invalid code signature: \(url.path)")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            throw NativePluginFailure(message: "cannot read plugin signature")
        }
        let pluginTeam = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var ownInfo: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess else {
            throw NativePluginFailure(message: "cannot verify host signing identity")
        }
        let ownTeam = (ownInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        // Ad-hoc development hosts still accept ad-hoc modules by default. A
        // release host requires the user's explicit opt-in for other publishers.
        thirdParty = pluginTeam != ownTeam
        guard allowThirdParty || !thirdParty else {
            throw NativePluginFailure(message: "third-party native plugins are disabled (native_plugins.allow_third_party); restart Tilr after changing settings")
        }
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url.appendingPathComponent("Contents/Resources/manifest.json")))
        guard manifest.id == id, Self.validVersion(manifest.version), manifest.abi == 1,
              expectedVersion == nil || expectedVersion == manifest.version,
              manifest.minOS.range(of: "^[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
            throw NativePluginFailure(message: "incompatible native plugin manifest: \(id)")
        }
        let parts = manifest.minOS.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2, ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: 0)) else {
            throw NativePluginFailure(message: "\(id) needs macOS \(manifest.minOS)")
        }
        let binary = url.appendingPathComponent("Contents/MacOS/Plugin")
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            throw NativePluginFailure(message: "\(id): \(dlerror().map { String(cString: $0) } ?? "cannot load module")")
        }
        self.handle = handle
        guard let symbol = dlsym(handle, "tilr_plugin_create_v1") else {
            // Keep the handle resident even when a faulty module omits its entry point.
            throw NativePluginFailure(message: "\(id): missing ABI 1 entry point")
        }
        create = unsafeBitCast(symbol, to: TLRPluginCreateV1.self)
    }

    func make() throws -> TLRNativePlugin {
        guard let pointer = create() else { throw NativePluginFailure(message: "\(manifest.id): factory returned nil") }
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        let selectors = ["abiVersion", "startWithHost:", "receive:channel:", "request:service:identifier:completion:",
                         "cancelRequest:", "pageDidNavigate", "configurationDidChange", "stop"]
        guard let plugin = object as? TLRNativePlugin,
              selectors.allSatisfy({ plugin.responds(to: NSSelectorFromString($0)) }), plugin.abiVersion == 1 else {
            throw NativePluginFailure(message: "\(manifest.id): factory did not return an ABI 1 plugin")
        }
        return plugin
    }
}

/// One weak host facade per provider. A provider may emit only declared events.
final class NativePluginContext: NSObject, TLRPluginHost {
    weak var session: NativePluginSession?
    let id: String
    let events: Set<String>
    init(session: NativePluginSession, id: String, events: [String]) { self.session = session; self.id = id; self.events = Set(events) }
    var origin: String { session?.tab?.app.origin.absoluteString ?? "" }
    var viewContainer: NSView { session?.tab?.webView ?? NSView() }
    var configuration: [String: Any] {
        var value = session?.configuration ?? [:]
        value["options"] = session?.pluginOptions[id] ?? [:]
        return value
    }
    var storageIdentifier: UUID? { Instance.storageID }
    func persistentIdentifier(_ identifier: UUID) -> UUID { Instance.profileStore(identifier) }
    func resolveSiteURL(_ url: URL) -> URL? { session?.tab?.siteFile(url) }
    func emit(_ event: String, detail: [String: Any]) {
        guard events.contains(event) else { return }
        session?.emit(event, detail: detail)
    }
}

/// Weak WK handler: WKUserContentController must not retain a tab's session.
final class NativePluginRelay: NSObject, WKScriptMessageHandler {
    weak var session: NativePluginSession?
    init(_ session: NativePluginSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receive(message)
    }
}

// Main-thread confined, including all ABI callbacks. Explicit assertions keep the
// manual isolation visible while the surrounding AppKit shell uses Swift 5 mode.
final class NativePluginSession: @unchecked Sendable {
    weak var tab: Tab?
    private struct Provider {
        let library: NativePluginLibrary
        let plugin: TLRNativePlugin
        let context: NativePluginContext
    }
    private var providers: [String: Provider] = [:]
    private var bridges: [String: (id: String, channel: String)] = [:]
    private var services: [String: String] = [:]
    private var failures: [String: String] = [:]
    private var controller: WKUserContentController?
    private let settings: Config.NativePlugins
    private(set) var configuration: [String: Any] = [:]
    private(set) var pluginOptions: [String: Any] = [:]
    private var pending: [UUID: (Result<[String: Any], Error>) -> Void] = [:]
    private var stopped = false

    init(tab: Tab, settings: Config.NativePlugins, browser: Config.Browser) {
        self.tab = tab
        self.settings = settings
        configure(browser: browser, options: settings.options)
        for id in settings.enabled {
            guard providers[id] == nil else { continue }
            do {
                let library = try NativePluginLibrary.open(id: id, directory: URL(fileURLWithPath: Config.resolve(settings.directory)), allowThirdParty: settings.allowThirdParty)
                let manifest = library.manifest
                let reserved = Set(["tilrNative", ConsoleRelay.name, AgentHost.name, LocalServerBridge.name])
                guard !manifest.bridges.keys.contains(where: { bridges[$0] != nil || reserved.contains($0) }),
                      !manifest.services.contains(where: { services[$0] != nil }),
                      manifest.events.allSatisfy({ $0.hasPrefix("tilr-") && $0 != "tilr-native" }) else {
                    throw NativePluginFailure(message: "duplicate or reserved native service/bridge: \(id)")
                }
                let plugin = try library.make()
                let context = NativePluginContext(session: self, id: id, events: manifest.events)
                providers[id] = Provider(library: library, plugin: plugin, context: context)
                for (name, channel) in manifest.bridges { bridges[name] = (id, channel) }
                for service in manifest.services { services[service] = id }
                plugin.start(host: context)
                print("native plugin: \(id) \(manifest.version) ← \(library.url.path)")
            } catch {
                failures[id] = error.localizedDescription
                print("native plugin \(id):", error.localizedDescription)
            }
        }
    }

    func attach(to controller: WKUserContentController) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.controller = controller
        controller.add(NativePluginRelay(self), name: "tilrNative")
        for name in bridges.keys { controller.add(NativePluginRelay(self), name: name) }
    }

    func configure(browser: Config.Browser, options: [String: Config.PluginValue]) {
        dispatchPrecondition(condition: .onQueue(.main))
        pluginOptions = options.mapValues(\.value)
        if let data = try? JSONEncoder().encode(browser),
           let value = try? JSONSerialization.jsonObject(with: data) {
            configuration["browser"] = value
        }
        for provider in providers.values { provider.plugin.configurationDidChange() }
    }

    /// Only the trusted top-level app document may call native plugin bridges.
    /// Embedded browser views have entirely different WKUserContentControllers.
    func receive(_ message: WKScriptMessage) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped, let tab, message.webView === tab.webView, message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url,
              trusted(frameURL, tab: tab),
              let body = message.body as? [String: Any] else { return }
        if message.name == "tilrNative" {
            guard let requestID = body["id"] as? String else { return }
            switch body["op"] as? String {
            case "describe":
                let result = providers.values.map { provider in
                    ["id": provider.library.manifest.id, "version": provider.library.manifest.version,
                     "channels": Array(provider.library.manifest.bridges.values), "events": provider.library.manifest.events] as [String: Any]
                }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
                emit("tilr-native", detail: ["id": requestID, "result": result])
            case "send":
                guard let id = body["plugin"] as? String, let provider = providers[id],
                      let channel = body["channel"] as? String, provider.library.manifest.bridges.values.contains(channel),
                      let payload = body["message"] as? [String: Any] else {
                    emit("tilr-native", detail: ["id": requestID, "error": "native plugin/channel unavailable or invalid message"])
                    return
                }
                provider.plugin.receive(payload, channel: channel)
                emit("tilr-native", detail: ["id": requestID, "result": ["accepted": true]])
            default: emit("tilr-native", detail: ["id": requestID, "error": "unknown native operation"])
            }
            return
        }
        guard let target = bridges[message.name] else { return }
        providers[target.id]?.plugin.receive(body, channel: target.channel)
    }

    func emit(_ event: String, detail: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped, let tab, let url = tab.webView.url, trusted(url, tab: tab),
              let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        let expected = Site.devURL ?? tab.app.origin
        // Check again in JS: navigation may finish between scheduling and evaluation.
        let source = """
        (() => {
          if (location.protocol !== \(Tab.literal((expected.scheme ?? "") + ":")) ||
              location.hostname !== \(Tab.literal(expected.host ?? "")) ||
              location.port !== \(Tab.literal(expected.port.map(String.init) ?? ""))) return;
          window.dispatchEvent(new CustomEvent(\(Tab.literal(event)), {detail: \(json)}));
        })()
        """
        tab.webView.evaluateJavaScript(source, completionHandler: nil)
    }

    private func trusted(_ url: URL, tab: Tab) -> Bool {
        let expected = Site.devURL ?? tab.app.origin
        return url.scheme == expected.scheme && url.host == expected.host && url.port == expected.port
    }

    func pageDidNavigate() { for provider in providers.values { provider.plugin.pageDidNavigate() } }

    @MainActor
    func request(service: String, body: [String: Any]) async throws -> [String: Any] {
        guard !stopped, let id = services[service], let provider = providers[id] else {
            throw NativePluginFailure(message: "native service \(service) unavailable; inspect native-plugins")
        }
        guard settings.requestTimeout.isFinite, settings.requestTimeout > 0 else {
            throw NativePluginFailure(message: "native_plugins.request_timeout must be positive")
        }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = DispatchWorkItem { [weak self] in
                    provider.plugin.cancelRequest(token.uuidString)
                    self?.pending.removeValue(forKey: token)?(.failure(NativePluginFailure(message: "native service \(service) timed out")))
                }
                pending[token] = { result in timer.cancel(); continuation.resume(with: result) }
                DispatchQueue.main.asyncAfter(deadline: .now() + settings.requestTimeout, execute: timer)
                provider.plugin.request(body, service: service, identifier: token.uuidString) { [weak self] value, error in
                    let result: Result<[String: Any], Error> = error.map { .failure($0) } ?? .success(value ?? [:])
                    Task { @MainActor in self?.pending.removeValue(forKey: token)?(result) }
                }
            }
        } onCancel: { [weak self] in
            DispatchQueue.main.async {
                self?.providers[id]?.plugin.cancelRequest(token.uuidString)
                self?.pending.removeValue(forKey: token)?(.failure(CancellationError()))
            }
        }
    }

    func status() -> [[String: Any]] {
        settings.enabled.map { id in
            if let provider = providers[id] {
                return ["id": id, "version": provider.library.manifest.version, "state": "loaded",
                        "path": provider.library.url.path, "services": provider.library.manifest.services,
                        "publisher": provider.library.thirdParty ? "third-party" : "app-publisher",
                        "updatePolicy": "restart-app"]
            }
            return ["id": id, "state": "unavailable", "error": failures[id] ?? "disabled"]
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        stopped = true
        controller?.removeScriptMessageHandler(forName: "tilrNative")
        for name in bridges.keys { controller?.removeScriptMessageHandler(forName: name) }
        controller = nil
        let completions = pending.values
        pending.removeAll()
        for complete in completions { complete(.failure(CancellationError())) }
        for provider in providers.values { provider.plugin.stop(); provider.context.session = nil }
        providers.removeAll()
    }

    deinit { stop() }
}
