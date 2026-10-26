import AppKit
import WebKit

/// The bundle seeds an offline first install. The server then has its own signed
/// update feed, version, channel and installation lifecycle, separate from Sparkle.
final class LocalServerHost: NSObject {
    static let shared = LocalServerHost()
    private var status = "Local server is not enabled in this instance."
    private var starting = false
    private var busy = false
    private var result: Result<[String: String]?, Error> = .success(nil)
    private var waiting: [(Result<[String: String]?, Error>) -> Void] = []
    private var installation: ServerInstallation?
    private var settings: Config.LocalServer?
    private var manifest: ServerInstallation.Manifest?
    private var updates: ServerUpdates?
    private var available: ServerUpdates.Release?
    private var timer: Timer?
    private var checkingStatus = false
    /// Removed in this run (dialog or config); the dialog then offers nothing.
    private var removed = false
    var didUpdate: (() -> Void)?

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// `local_server.enabled: false` removes what the app installed, at launch and on config reload.
    func start(settings: Config.LocalServer, origins: [String], allowed: Bool) {
        guard allowed, !CommandLine.arguments.contains("--no-local-server") else { return }
        guard let bundle = Bundle.main.resourceURL?.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Resources/server/app-managed.json").path) else {
            // Only a release build manages the server, so only it removes one.
            status = "This development build has no bundled server."
            return
        }
        guard settings.enabled else {
            let install = makeInstallation(bundle: bundle, settings: settings, origins: origins, appBuild: 0, protocolVersion: 0)
            if installation == nil { installation = install }
            uninstall(install, userInitiated: false)
            return
        }
        guard settings.port > 0, settings.commandTimeout > 0, settings.startupTimeout > 0, settings.retryInterval > 0,
              settings.checkInterval > 0, settings.downloadTimeout > 0, settings.maxFeedBytes > 0, settings.maxDownloadBytes > 0,
              ["stable", "beta"].contains(settings.updateChannel),
              let appBuildText = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let appBuild = Int(appBuildText),
              let protocolVersion = Bundle.main.object(forInfoDictionaryKey: "TilrServerProtocolVersion") as? Int else {
            finish(.failure(ServerInstallation.Failure("Invalid local_server configuration or missing release compatibility metadata.")))
            return
        }
        self.settings = settings
        starting = true
        removed = false
        status = "Preparing the local server…"
        let install = makeInstallation(bundle: bundle, settings: settings, origins: origins,
                                       appBuild: appBuild, protocolVersion: protocolVersion)
        installation = install
        if let base = Bundle.main.object(forInfoDictionaryKey: "TilrServerFeedBaseURL") as? String,
           let keyText = Bundle.main.object(forInfoDictionaryKey: "TilrServerPublicKey") as? String,
           let key = Data(base64Encoded: keyText), key.count == 32,
           let url = URL(string: base + "/" + Self.architecture + "/" + settings.updateChannel + ".json"), url.scheme == "https" {
            updates = ServerUpdates(feedURL: url, publicKey: key, channel: settings.updateChannel,
                arch: Self.architecture, appBuild: appBuild, protocolVersion: protocolVersion,
                timeout: settings.downloadTimeout, maxFeedBytes: settings.maxFeedBytes, maxBinaryBytes: settings.maxDownloadBytes)
        }
        Task { @MainActor in
            do {
                let (installed, credentials) = try await Self.prepare(install, settings)
                manifest = installed
                status = description(installed)
                finish(.success(credentials))
                if settings.autoCheck {
                    checkUpdates(userInitiated: false)
                    scheduleChecks(every: settings.checkInterval)
                }
            } catch {
                // Allow a server-only recovery update even when the installed server
                // is incompatible with a newly installed app. Do not stop it.
                manifest = try? JSONDecoder().decode(ServerInstallation.Manifest.self, from: Data(contentsOf: install.receipt))
                finish(.failure(error))
            }
        }
    }

    /// The config file changed: `enabled: false` removes the service now; `true` installs it when
    /// this run has not (it was off at launch, or removed since).
    func configChanged(settings: Config.LocalServer, origins: [String], allowed: Bool) {
        guard !starting, !busy else { return }
        if !settings.enabled || self.settings == nil || removed {
            start(settings: settings, origins: origins, allowed: allowed)
        }
    }

    private func makeInstallation(bundle: URL, settings: Config.LocalServer, origins: [String],
                                  appBuild: Int, protocolVersion: Int) -> ServerInstallation {
        var install = ServerInstallation(source: bundle.appendingPathComponent("Helpers"),
            root: Config.defaultDir.appendingPathComponent("server"),
            agents: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
            label: "dev.tilr.server", port: settings.port, timeout: settings.commandTimeout,
            origins: Array(Set(origins)), appBuild: appBuild, protocolVersion: protocolVersion, architecture: Self.architecture,
            sourceManifest: bundle.appendingPathComponent("Resources/server/app-managed.json"))
        install.progress = Self.report
        return install
    }

    /// launchd steps show in the dialog while they run.
    private static func report(_ step: String) {
        DispatchQueue.main.async { shared.status = step }
    }

    private static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { reply in
            DispatchQueue.global(qos: .utility).async { reply.resume(with: Result { try work() }) }
        }
    }

    private func uninstall(_ install: ServerInstallation, userInitiated: Bool) {
        guard !busy, !starting else { return }
        busy = true
        timer?.invalidate()
        timer = nil
        Task { @MainActor in
            do {
                let outcome = try await Self.background { try install.remove() }
                busy = false
                removed = true
                manifest = nil
                available = nil
                updates = nil
                result = .failure(ServerInstallation.Failure("The local server is not installed."))
                status = outcome == .removed
                    ? "The local server was removed. Sessions, tokens and logs remain in \(install.state.path)."
                    : "The local server is not installed."
                print("local server:", status)
                if userInitiated { showStatus() }
            } catch {
                busy = false
                status = "The local server was not removed: " + error.localizedDescription
                print("local server:", status)
                notice(status)
            }
        }
    }

    private func restartServer() {
        guard !busy, !starting, let installation, let settings else { return }
        busy = true
        status = "Restarting the local server…"
        let version = manifest?.serverVersion
        Task { @MainActor in
            do {
                let credentials = try await Self.background {
                    try installation.restart()
                    return try Self.waitReady(installation, version: version, settings)
                }
                result = .success(credentials)
                didUpdate?()
                status = (manifest.map(description) ?? "") + "\n\nThe local server restarted with its new service definition."
                busy = false
                showStatus()
            } catch {
                busy = false
                status = "The local server did not restart: " + error.localizedDescription
                notice(status)
            }
        }
    }

    @objc private func checkTimer() { checkUpdates(userInitiated: false) }

    private func scheduleChecks(every interval: TimeInterval) {
        timer?.invalidate()
        let next = Timer(timeInterval: interval, target: self, selector: #selector(checkTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private static func prepare(_ install: ServerInstallation, _ settings: Config.LocalServer) async throws -> (ServerInstallation.Manifest, [String: String]) {
        try await background {
            let manifest = try install.install()
            return (manifest, try waitReady(install, version: manifest.serverVersion, settings))
        }
    }

    /// Until the server answers an authenticated connection with `version` (any, when nil).
    private static func waitReady(_ install: ServerInstallation, version: String?, _ settings: Config.LocalServer) throws -> [String: String] {
        try install.waitReady(version: version, startupTimeout: settings.startupTimeout,
                              retryInterval: settings.retryInterval)
    }

    private func description(_ manifest: ServerInstallation.Manifest) -> String {
        "Server: \(manifest.serverVersion)\nChannel: \(settings?.updateChannel ?? "stable")\n\(installation?.endpoint ?? "")\n\nUpdates independently of the Mac application. Closing Tilr leaves terminals running until logout."
    }

    func checkUpdates(userInitiated: Bool) {
        guard !starting, !busy else { if userInitiated { showStatus() }; return }
        guard let updates, let manifest else {
            if userInitiated { notice("Server updates are unavailable in this instance or release.") }
            return
        }
        busy = true
        available = nil
        Task { @MainActor in
            do {
                available = try await updates.check(installed: manifest)
                busy = false
                if let available {
                    status = description(manifest) + "\n\nAvailable: " + available.manifest.serverVersion
                    if userInitiated { offer(available) }
                } else {
                    status = description(manifest) + "\n\nNo newer compatible server release is available."
                    if userInitiated { showStatus() }
                }
            } catch {
                busy = false
                status = description(manifest) + "\n\nCould not check server updates: " + error.localizedDescription
                // Offline/404 feeds must not prevent local use or invalidate credentials.
                if let message = ServerUpdates.message(for: error, userInitiated: userInitiated) {
                    notice(message)
                } else {
                    print("local server: update check:", error.localizedDescription)
                }
            }
        }
    }

    private func offer(_ release: ServerUpdates.Release) {
        let alert = NSAlert()
        alert.messageText = "Server update available"
        alert.informativeText = "Install \(release.manifest.serverVersion)? The Mac application will stay on its current version."
        alert.addButton(withTitle: "Update Server")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { installUpdate(release) }
    }

    private func installUpdate(_ release: ServerUpdates.Release) {
        guard !busy, let updates, let installation, let settings else { return }
        busy = true
        status = "Downloading and updating the server…"
        Task { @MainActor in
            do {
                let source = try await updates.stage(release)
                defer { try? FileManager.default.removeItem(at: source) }
                var staged = ServerInstallation(source: source, root: installation.root, agents: installation.agents,
                    label: installation.label, port: installation.port, timeout: installation.timeout,
                    origins: installation.origins, appBuild: installation.appBuild,
                    protocolVersion: installation.protocolVersion, architecture: installation.architecture)
                staged.progress = installation.progress
                let (installed, credentials) = try await Self.prepare(staged, settings)
                manifest = installed
                available = nil
                result = .success(credentials)
                didUpdate?()
                status = description(installed) + "\n\nServer update completed."
                busy = false
                showStatus()
            } catch {
                busy = false
                status = "Server update did not complete: " + error.localizedDescription
                notice(status)
            }
        }
    }

    private func finish(_ outcome: Result<[String: String]?, Error>) {
        starting = false
        result = outcome
        if case .failure(let error) = outcome {
            status = error.localizedDescription
            print("local server:", status)
            notice(status)
        }
        let callbacks = waiting
        waiting.removeAll()
        callbacks.forEach { $0(outcome) }
    }

    func credentials(_ reply: @escaping (Result<[String: String]?, Error>) -> Void) {
        if starting { waiting.append(reply) } else { reply(result) }
    }

    func showStatus() {
        guard !checkingStatus else { return }
        guard !starting, !busy else { presentStatus("Starting…", actions: false); return }
        guard let installation else {
            presentStatus("Not started by the app", actions: false)
            return
        }
        guard installation.isInstalled else {
            presentStatus("Not installed", actions: false)
            return
        }
        checkingStatus = true
        Task { @MainActor in
            let (runningVersion, pending): (String?, Bool) = await withCheckedContinuation { reply in
                DispatchQueue.global(qos: .utility).async {
                    let response = try? installation.command(installation.binary,
                        ["ps", "--url", installation.endpoint, "--server-version"])
                    reply.resume(returning: (response?.status == 0 ? response?.text : nil, installation.restartPending()))
                }
            }
            checkingStatus = false
            if let runningVersion, !runningVersion.isEmpty {
                presentStatus("Running — \(runningVersion)", pending: pending)
            } else {
                presentStatus("Not running or unreachable", detail: "The server did not answer the connection check.", pending: pending)
            }
        }
    }

    private func presentStatus(_ state: String, detail: String? = nil, actions: Bool = true, pending: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Local Tilr Server: " + state
        let pending = actions && pending
        alert.informativeText = [detail, status, pending ? "A new service definition is waiting; restart to apply." : nil]
            .compactMap { $0 }.joined(separator: "\n\n")
        var buttons: [(String, () -> Void)] = [("OK", {})]
        if actions {
            buttons.append(("Refresh", { [weak self] in self?.showStatus() }))
            if let available, !busy { buttons.append(("Update Server…", { [weak self] in self?.offer(available) })) }
            if pending { buttons.append(("Restart Server…", { [weak self] in self?.confirmRestart() })) }
            buttons.append(("Remove Local Server…", { [weak self] in self?.confirmRemove() }))
        }
        buttons.forEach { alert.addButton(withTitle: $0.0) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if buttons.indices.contains(index) { buttons[index].1() }
    }

    private func confirmRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart the local server?"
        alert.informativeText = "The server restarts with its new service definition. Open terminal panes will close."
        alert.addButton(withTitle: "Restart Server").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { restartServer() }
    }

    private func confirmRemove() {
        guard let installation else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the local server?"
        alert.informativeText = "Tilr stops the service, removes it from Login Items and deletes the installed server. Open terminal panes will close. Sessions, tokens and logs in \(installation.state.path) are kept.\n\nThe next launch installs it again unless local_server.enabled is false in config.yml."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { uninstall(installation, userInitiated: true) }
    }

    private func notice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Local Tilr Server"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Only the trusted main Tilr page may request credentials, never remote pages or subframes.
final class LocalServerBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "tilrLocalServer"
    weak var tab: Tab?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "tilr",
              message.frameInfo.securityOrigin.host == tab.app.origin.host,
              message.webView === tab.webView,
              message.body as? String == "credentials" else {
            replyHandler(nil, "Local server access is restricted to the Tilr app page.")
            return
        }
        LocalServerHost.shared.credentials { result in
            switch result {
            case .success(let credentials): replyHandler(credentials as Any? ?? NSNull(), nil)
            case .failure(let error): replyHandler(nil, error.localizedDescription)
            }
        }
    }
}
