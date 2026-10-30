import AppKit
import WebKit

/// The bundle seeds an offline first install; the ordinary daemon owns subsequent updates,
/// which the application runs at every start to keep it on the latest release.
final class LocalServerHost: NSObject {
    static let shared = LocalServerHost()
    private let homeDirectory: URL

    private let resolveRunningExecutable: (() throws -> URL?)?
    private let receiveNotice: ((String) -> Void)?
    var updateChannel: () -> String = { "stable" }
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         receiveNotice: ((String) -> Void)? = nil,
         resolveRunningExecutable: (() throws -> URL?)? = nil) {
        self.resolveRunningExecutable = resolveRunningExecutable
        self.homeDirectory = homeDirectory
        self.receiveNotice = receiveNotice
        super.init()
    }
    private(set) var status = "Local server is not enabled in this instance."
    private var starting = false
    private var busy = false
    private var result: Result<[String: String]?, Error> = .success(nil)
    private var waiting: [(Result<[String: String]?, Error>) -> Void] = []
    private var installation: ServerInstallation?
    private var settings: Config.LocalServer?
    private var installedVersion: String?
    private var runningVersion: String?
    private var versionError: String?
    private var checkingStatus = false
    /// Removed in this run (dialog or config); the dialog then offers nothing.
    private var removed = false
    var didUpdate: (() -> Void)?
    private var launchUpdate: Task<Void, Never>?

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// `local_server.enabled: false` disables application integration without removing the shared daemon.
    func start(settings: Config.LocalServer, origins: [String], allowed: Bool) {
        guard allowed, !CommandLine.arguments.contains("--no-local-server") else { return }
        guard let bundle = Bundle.main.resourceURL?.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Helpers/tilrd").path) else {
            // Only a release build manages the server, so only it removes one.
            status = "This development build has no bundled server."
            return
        }
        guard settings.enabled else {
            self.settings = nil
            result = .success(nil)
            status = "Local server integration is disabled."
            return
        }
        guard settings.port == 7890, settings.commandTimeout > 0, settings.startupTimeout > 0, settings.retryInterval > 0,
              settings.updateTimeout > 0,
              let protocolVersion = Bundle.main.object(forInfoDictionaryKey: "TilrServerProtocolVersion") as? Int else {
            finish(.failure(ServerInstallation.Failure("Invalid local_server configuration (port must be 7890) or missing release compatibility metadata.")))
            return
        }
        self.settings = settings
        starting = true
        removed = false
        status = "Preparing the local server…"
        let install = makeInstallation(bundle: bundle, settings: settings, origins: origins,
                                       protocolVersion: protocolVersion)
        installation = install
        launchUpdate = Task { @MainActor in
            do {
                let (_, credentials) = try await Self.prepare(install, settings)
                await inspectVersions(install)
                status = versionDescription
                finish(.success(credentials))
            } catch {
                // Allow a server-only recovery update even when the installed server
                // is incompatible with a newly installed app. Do not stop it.
                await inspectVersions(install)
                status = versionDescription
                finish(.failure(error))
                if install.needsNewerApplication(error) { return }
            }
            await updateAtLaunch(install, settings)
        }
    }

    /// Ready credentials stay in use while the daemon updates itself; an offline or failed
    /// update keeps the installed pair and reports it without interrupting the user.
    @MainActor private func updateAtLaunch(_ install: ServerInstallation, _ settings: Config.LocalServer) async {
        guard install.isInstalled, !busy, !removed, self.settings != nil else { return }
        busy = true
        defer { busy = false }
        let wasReady: Bool
        if case .success(.some) = result { wasReady = true } else { wasReady = false }
        do {
            try await runUpdate(install, settings)
            status = versionDescription
        } catch {
            await inspectVersions(install)
            status = versionDescription + "\n\nCould not update tilrd at launch: " + error.localizedDescription
            print("local server:", status)
            // An offline update leaves the daemon usable; one that installed a release this
            // application cannot speak to (a newer protocol) must not fail silently.
            if wasReady, case .failure = result { notice(status) }
        }
    }

    /// The launch update of the latest start, for callers that need its outcome.
    func waitForLaunchUpdate() async { await launchUpdate?.value }

    /// The config file changed: `enabled: false` disables integration; `true` discovers the daemon when
    /// this run has not (it was off at launch, or removed since).
    func configChanged(settings: Config.LocalServer, origins: [String], allowed: Bool) {
        guard !starting, !busy else { return }
        if !settings.enabled || self.settings == nil || removed {
            start(settings: settings, origins: origins, allowed: allowed)
        }
    }

    private func makeInstallation(bundle: URL, settings: Config.LocalServer, origins: [String],
                                  protocolVersion: Int) -> ServerInstallation {
        var install = ServerInstallation(source: bundle.appendingPathComponent("Helpers"),
            root: homeDirectory.appendingPathComponent(".local/bin"),
            agents: homeDirectory.appendingPathComponent("Library/LaunchAgents"),
            label: "sh.tilr.tilrd", port: 7890, timeout: settings.commandTimeout,
            origins: Array(Set(origins)), protocolVersion: protocolVersion, architecture: Self.architecture)
        install.runningExecutable = resolveRunningExecutable
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
        Task { @MainActor in
            do {
                let outcome = try await Self.background { try install.remove(confirmExternal: Self.confirmExternalRemoval) }
                if outcome == .declined { busy = false; return }
                busy = false
                removed = true
                installedVersion = nil
                runningVersion = nil
                versionError = nil
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

    private var versionDescription: String {
        var lines = ["Installed tilrd: " + (installedVersion ?? "Unknown"),
                     "Running tilrd: " + (runningVersion ?? "Not running or unreachable")]
        if let versionError { lines.append(versionError) }
        lines.append("Use Update tilrd to update the shared daemon. Closing Tilr leaves terminals running until logout.")
        return lines.joined(separator: "\n\n")
    }

    @MainActor private func inspectVersions(_ install: ServerInstallation) async {
        let inspected = await withCheckedContinuation { reply in
            DispatchQueue.global(qos: .utility).async {
                let installed = try? install.installedVersion()
                let running = Result { try install.runningVersion() }
                reply.resume(returning: (installed, running))
            }
        }
        installedVersion = inspected.0
        switch inspected.1 {
        case .success(let version): runningVersion = version; versionError = nil
        case .failure(let error): runningVersion = nil; versionError = error.localizedDescription
        }
    }

    /// Called by the Local Server button; a failed command retains the previous credentials.
    @MainActor func updateTilrd() async {
        guard !starting, !busy, let installation, let settings else { return }
        busy = true
        defer { busy = false }
        do {
            try await runUpdate(installation, settings)
            status = versionDescription + "\n\nThe tilrd update command completed."
        } catch {
            await inspectVersions(installation)
            status = versionDescription + "\n\nCould not update tilrd: " + error.localizedDescription
        }
        notice(status)
    }

    /// The selected daemon installs the latest tilrd and tilr of the channel read now, then
    /// the application waits for the version it reports. Pages reconnect only on a change.
    @MainActor private func runUpdate(_ installation: ServerInstallation, _ settings: Config.LocalServer) async throws {
        let channel = updateChannel()
        status = "Updating tilrd (\(channel))…"
        var updater = installation
        updater.timeout = settings.updateTimeout
        let previous = runningVersion
        let wasReady: Bool
        if case .success(.some) = result { wasReady = true } else { wasReady = false }
        let version = try await Self.background { try updater.update(channel: channel) }
        let credentials: [String: String]
        do {
            credentials = try await Self.background {
                try Self.waitReady(installation, version: version, settings)
            }
        } catch {
            result = .failure(error)
            didUpdate?()
            throw error
        }
        await inspectVersions(installation)
        result = .success(credentials)
        if !wasReady || previous != version { didUpdate?() }
    }

    private func finish(_ outcome: Result<[String: String]?, Error>) {
        starting = false
        result = outcome
        if case .failure(let error) = outcome {
            if error.localizedDescription != versionError {
                status = [status, error.localizedDescription].joined(separator: "\n\n")
            }
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
            await inspectVersions(installation)
            checkingStatus = false
            status = versionDescription
            presentStatus(runningVersion.map { "Running — \($0)" } ?? "Not running or unreachable")
        }
    }

    private func presentStatus(_ state: String, actions: Bool = true) {
        let alert = NSAlert()
        alert.messageText = "Local Tilr Server: " + state
        alert.informativeText = status
        var buttons: [(String, () -> Void)] = [("OK", {})]
        if actions {
            buttons.append(("Refresh", { [weak self] in self?.showStatus() }))
            if installation?.isInstalled == true {
                buttons.append(("Update tilrd", { [weak self] in Task { await self?.updateTilrd() } }))
                buttons.append(("Remove Local Server…", { [weak self] in self?.confirmRemove() }))
            }
        }
        buttons.forEach { alert.addButton(withTitle: $0.0) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if buttons.indices.contains(index) { buttons[index].1() }
    }

    private func confirmRemove() {
        guard let installation else { return }
        uninstall(installation, userInitiated: true)
    }

    /// Called from the background removal operation; only the consent dialog runs on the UI thread.
    private static func confirmExternalRemoval() -> Bool {
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = "Remove tilrd?"
            alert.informativeText = "This tilrd was not installed by Tilr. Removing it unregisters its startup service and deletes its executable. Terminal clients also use this server. Existing sessions, tokens and logs are kept."
            alert.addButton(withTitle: "No")
            alert.addButton(withTitle: "Yes").hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    func removeForAppUninstall(settings: Config.LocalServer) async throws {
        guard !starting, !busy else { throw ServerInstallation.Failure("Wait for the local server operation to finish, then try uninstalling again.") }
        busy = true
        defer { busy = false }
        let install: ServerInstallation
        if let installation { install = installation }
        else {
            guard let bundle = Bundle.main.resourceURL?.deletingLastPathComponent() else {
                throw ServerInstallation.Failure("Cannot locate the application helpers.")
            }
            install = makeInstallation(bundle: bundle, settings: settings, origins: [], protocolVersion: 1)
            try await Self.background { try install.locateForRemoval() }
        }
        _ = try await Self.background { try install.remove(confirmExternal: Self.confirmExternalRemoval) }
    }

    func stop() {
        didUpdate = nil
    }

    private func notice(_ message: String) {
        if let receiveNotice { receiveNotice(message); return }
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
