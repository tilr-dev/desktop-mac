import Foundation
import CryptoKit
import Darwin

/// A stable executable outside .app, seeded by the bundle and independently updated.
/// An app upgrade retains a newer compatible installed server. launchd and explicit server reloads keep
/// using that same path. Never restart a running job during an upgrade.
struct ServerInstallation {
    struct Manifest: Codable, Equatable {
        let version: String
        let build: Int
        let arch: String
        let serverVersion: String
        let sha256: String
        let protocolVersion: Int
        let minAppBuild: Int
        let maxAppBuild: Int?

        func supports(appBuild: Int, protocolVersion: Int, arch: String) -> Bool {
            build > 0 && self.protocolVersion == protocolVersion && appBuild >= minAppBuild
                && (maxAppBuild.map { appBuild <= $0 } ?? true)
                && (self.arch == arch || self.arch == "universal")
        }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    struct Output {
        let status: Int32
        let text: String
    }
    typealias Runner = (URL, [String]) throws -> Output
    let source: URL
    let root: URL
    let agents: URL
    let label: String
    let port: UInt16
    let timeout: TimeInterval
    let origins: [String]
    let appBuild: Int
    let protocolVersion: Int
    let architecture: String
    var runner: Runner? = nil
    var portCheck: (() throws -> Void)? = nil
    var sourceManifest: URL? = nil
    /// Tests: the running server's live pane count instead of asking it (nil = no answer).
    var paneCount: (() -> Int?)? = nil
    /// Each launchd step, for the status the app shows while it works.
    var progress: ((String) -> Void)? = nil

    var binary: URL { root.appendingPathComponent("tilrd") }
    var receipt: URL { root.appendingPathComponent("app-managed.json") }
    var plist: URL { agents.appendingPathComponent(label + ".plist") }
    var endpoint: String { "ws://127.0.0.1:\(port)" }
    var service: String { "gui/\(getuid())/\(label)" }
    var state: URL { root.appendingPathComponent("state") }
    /// Written when our plist was rewritten but launchd still runs the old definition because the
    /// server had live panes; cleared by the next bootstrap. Only a fallback: see `restartPending`.
    var restartMarker: URL { root.appendingPathComponent("restart-pending") }
    /// Our plist or our receipt is on disk: there is something for `remove()` to take away.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plist.path) || FileManager.default.fileExists(atPath: receipt.path)
    }

    func command(_ executable: URL, _ args: [String]) throws -> Output {
        if let runner { return try runner(executable, args) }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: log.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Cannot create server check log")
        }
        defer { try? FileManager.default.removeItem(at: log) }
        let file = try FileHandle(forWritingTo: log)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = file
        process.standardError = file
        // App environment overrides must never repoint the managed server's state.
        var env = ProcessInfo.processInfo.environment
        env["TILR_STATE_DIR"] = state.path
        env["TILR_RUNTIME_DIR"] = root.appendingPathComponent("runtime").path
        env.removeValue(forKey: "TILR_CONFIG")
        process.environment = env
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + timeout) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw Failure("Timed out checking the local server (\(executable.lastPathComponent)).")
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Output(status: process.terminationStatus, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Authenticate the running supervisor and wait for the installed release, without stopping it.
    func waitReady(version: String?, startupTimeout: TimeInterval, retryInterval: TimeInterval,
                   now: () -> Date = Date.init,
                   wait: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws -> [String: String] {
        progress?("Waiting for the local server on port \(port)…")
        let deadline = now().addingTimeInterval(startupTimeout)
        var runningVersion: String?
        repeat {
            if let check = try? command(binary, ["ps", "--url", endpoint, "--server-version"]),
               check.status == 0, !check.text.isEmpty {
                runningVersion = check.text
                if version == nil || check.text == version { return try credentials() }
            }
            wait(retryInterval)
        } while now() < deadline
        let mismatch: String
        if let version, let runningVersion {
            mismatch = " Reload did not complete: running version \(runningVersion), expected \(version)."
        } else {
            mismatch = ""
        }
        throw Failure("The local server did not become ready.\(mismatch) See \(root.appendingPathComponent("server.log").path). Existing processes were not stopped.")
    }

    func launchctl(_ args: [String]) throws -> Output {
        try command(URL(fileURLWithPath: "/bin/launchctl"), args)
    }

    func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Shared by the offline bundle installer and signed server downloads.
    /// File/receipt recovery is idempotent if the process died between their renames.
    func install() throws -> Manifest {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = try lock()
        defer { flock(fd, LOCK_UN); close(fd) }

        // Recover the binary/receipt transaction before comparing against an older bundle.
        // Before rename: keep the old receipt. After rename: finish the new receipt and
        // keep the transaction pending until reload has been requested (or the job started).
        let pending = root.appendingPathComponent("pending-server.json")
        var replacementPending = false
        if fm.fileExists(atPath: pending.path) {
            let pendingData = try Data(contentsOf: pending)
            let incoming = try JSONDecoder().decode(Manifest.self, from: pendingData)
            if (try? hash(binary)) == incoming.sha256 {
                try pendingData.write(to: receipt, options: .atomic)
                replacementPending = true
            } else {
                try fm.removeItem(at: pending)
            }
        }
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("tilrd.new.") {
            try fm.removeItem(at: file)
        }

        var data = try Data(contentsOf: sourceManifest ?? source.appendingPathComponent("app-managed.json"))
        var wanted = try JSONDecoder().decode(Manifest.self, from: data)
        var payload = source.appendingPathComponent("tilrd")
        let existing: Manifest?
        if fm.fileExists(atPath: receipt.path) {
            existing = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: receipt))
        } else {
            existing = nil
            guard !fm.fileExists(atPath: binary.path) else {
                throw Failure("An unmanaged executable already occupies \(binary.path). It was not replaced.")
            }
        }
        if let existing {
            if existing.build > wanted.build {
                // Bundle is a bootstrap copy, never a reason to downgrade a newer server.
                wanted = existing
                payload = binary
                data = try Data(contentsOf: receipt)
            } else if existing.build == wanted.build && existing != wanted {
                throw Failure("Different server contents use the same server release number.")
            }
        }
        guard wanted.supports(appBuild: appBuild, protocolVersion: protocolVersion, arch: architecture) else {
            throw Failure("The server is incompatible with this application. Check for Server Updates or update Tilr; the installed server was not downgraded or stopped.")
        }
        guard try hash(payload) == wanted.sha256 else { throw Failure("Server checksum mismatch") }
        let signature = try command(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", payload.path])
        guard signature.status == 0 else { throw Failure("Server signature verification failed") }
        let version = try command(payload, ["--version"])
        guard version.status == 0, version.text.hasPrefix("tilrd \(wanted.serverVersion) (") else {
            throw Failure("Server cannot run or has an unexpected version")
        }

        let job: [String: Any] = [
            "Label": label,
            // The binary itself, so launchd and Login Items name the signed server. Panes get the
            // user's login environment from the server, which runs their shell as a login shell.
            "ProgramArguments": [binary.path, "--listen", "127.0.0.1:\(port)", "--config", root.appendingPathComponent("origins.toml").path],
            "EnvironmentVariables": ["TILR_STATE_DIR": state.path,
                                     "TILR_RUNTIME_DIR": root.appendingPathComponent("runtime").path],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": root.appendingPathComponent("server.log").path,
            "StandardErrorPath": root.appendingPathComponent("server.log").path,
            // macOS 13+: Login Items and the background-activity notice show the app (name, icon)
            // instead of the signing team. Only the default instance installs the server.
            "AssociatedBundleIdentifiers": [Self.appBundleIdentifier],
        ]
        let jobState = try launchctl(["print", service])
        var loaded = jobState.status == 0
        let running = loaded && jobState.text.contains("state = running")
        // Our job with another definition (an earlier Tilr's, a changed port or environment):
        // rewritten and applied. Another program's plist under our name is refused.
        var changed = false
        if fm.fileExists(atPath: plist.path) {
            let old = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
            if let old = old as? NSDictionary, old.isEqual(to: job) {
            } else if let old = old as? [String: Any], Self.isOwnJob(old, label: label, binary: binary) {
                changed = true
            } else {
                throw Failure("\(plist.path) is not Tilr's local server service. It was left untouched.")
            }
        } else if loaded {
            throw Failure("A service named \(label) is loaded without Tilr's file \(plist.path). It was left untouched.")
        }
        // A separately installed server (or another application) may own this port.
        if !loaded { try checkPort() }

        let needsCopy = (try? hash(binary)) != wanted.sha256
        let configFile = root.appendingPathComponent("origins.toml")
        let encodedOrigins = String(decoding: try JSONSerialization.data(withJSONObject: origins.sorted(), options: [.withoutEscapingSlashes]), as: UTF8.self)
        let configData = Data(("# Managed by Tilr.app; regenerated at launch.\nallow_origins = " + encodedOrigins + "\n").utf8)
        let configChanged = (try? Data(contentsOf: configFile)) != configData
        if needsCopy {
            let staged = root.appendingPathComponent("tilrd.new.\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: payload, to: staged)
            if fm.fileExists(atPath: binary.path) {
                let previous = root.appendingPathComponent("tilrd.previous")
                try? fm.removeItem(at: previous)
                try fm.copyItem(at: binary, to: previous)
                if fm.fileExists(atPath: receipt.path) {
                    try Data(contentsOf: receipt).write(to: root.appendingPathComponent("app-managed.previous.json"), options: .atomic)
                }
            }
            // Mark it managed before exposing the executable: its standalone updater
            // must never fetch a different release from the server CDN.
            if configChanged { try configData.write(to: configFile, options: .atomic) }
            try data.write(to: pending, options: .atomic)
            if existing == nil { try data.write(to: receipt, options: .atomic) }
            guard rename(staged.path, binary.path) == 0 else { throw Failure("Cannot replace the installed server") }
            try data.write(to: receipt, options: .atomic)
            replacementPending = true
        }
        if !needsCopy && configChanged { try configData.write(to: configFile, options: .atomic) }
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        if changed || !fm.fileExists(atPath: plist.path) {
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
        }
        // launchd keeps the definition it loaded until bootout. A stopped job, or a running one
        // with no live panes, has nothing to lose: replace it now. Live panes (or a server that
        // does not answer) keep the old definition; the restart waits for the user or the next launch.
        if loaded && (changed || restartPending(printed: jobState.text)) {
            if !running || livePanes() == 0 {
                progress?("Stopping the local server to apply its new service definition…")
                let result = try launchctl(["bootout", service])
                guard result.status == 0 else { throw Failure("Cannot replace the local server service: \(result.text)") }
                loaded = false
            } else {
                try Data().write(to: restartMarker, options: .atomic)
            }
        }
        _ = try credentials()
        if !loaded {
            try bootstrapJob()
        } else if !running {
            // No -k: start a stopped job, never kill/restart an existing supervisor.
            let result = try launchctl(["kickstart", service])
            guard result.status == 0 else { throw Failure("Cannot start the local server: \(result.text)") }
        } else if replacementPending || configChanged {
            // The server reloads only on request. One signal applies both the installed binary
            // and origins through its session-preserving path, without restarting the job.
            do {
                let result = try launchctl(["kill", "SIGUSR1", service])
                guard result.status == 0 else { throw Failure(result.text) }
            } catch {
                if replacementPending {
                    throw Failure("The server update was installed, but the local server was not reloaded: \(error.localizedDescription)")
                }
                throw Failure("Cannot reload the local server's allowed origins: \(error.localizedDescription)")
            }
        }
        if replacementPending { try fm.removeItem(at: pending) }
        return wanted
    }

    /// The app the job is attributed to in Login Items; a bare test executable has no bundle.
    static var appBundleIdentifier: String { Bundle.main.bundleIdentifier ?? "dev.tilr.mac" }

    /// Whether `old` is a job Tilr wrote: our Label, and it runs our installed `binary`, directly
    /// or (an earlier Tilr) through `/bin/zsh -lc`. Its other keys may differ; they are ours to replace.
    static func isOwnJob(_ old: [String: Any], label: String, binary: URL) -> Bool {
        guard old["Label"] as? String == label, let args = old["ProgramArguments"] as? [String] else { return false }
        return args.first == binary.path
            || (args.first == "/bin/zsh" && args.dropFirst().first == "-lc" && args.contains(binary.path))
    }

    /// Whether launchd runs another definition than our plist file. Read from launchd itself
    /// (`launchctl print`: program, arguments, environment), so a login that loaded the new file
    /// counts as applied; the marker decides only when that output cannot be parsed. A match, or
    /// a job that is not loaded (its next bootstrap reads the file), clears the marker.
    func restartPending(printed: String? = nil) -> Bool {
        let fm = FileManager.default
        let marker = fm.fileExists(atPath: restartMarker.path)
        var text = printed
        if text == nil {
            guard let loaded = try? launchctl(["print", service]) else { return marker }
            if loaded.status != 0 { try? fm.removeItem(at: restartMarker); return false }
            text = loaded.text
        }
        guard let file = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              let same = Self.loadedDefinition(text ?? "", matches: file) else { return marker }
        if same { try? fm.removeItem(at: restartMarker) }
        return !same
    }

    /// Variables launchd adds to every job's `environment` block.
    static let launchdEnvironment: Set<String> = ["OSLogRateLimit"]

    /// Compares `launchctl print`'s program, arguments and environment with a job definition.
    /// nil when the output has no program or arguments block (another format, or not loaded),
    /// or no environment block while the job sets variables.
    static func loadedDefinition(_ printed: String, matches job: [String: Any]) -> Bool? {
        var program: String?
        var arguments: [String]?
        var environment: [String: String]?
        var block: String?
        var items: [String] = []
        for line in printed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let name = block {
                if line == "\t}" {
                    if name == "arguments" {
                        arguments = items
                    } else {
                        var pairs: [String: String] = [:]
                        for item in items {
                            guard let arrow = item.range(of: " => ") else { return nil }
                            pairs[String(item[..<arrow.lowerBound])] = String(item[arrow.upperBound...])
                        }
                        environment = pairs
                    }
                    block = nil
                    items = []
                } else {
                    items.append(line.trimmingCharacters(in: .whitespaces))
                }
            } else if line.hasPrefix("\tprogram = ") {
                program = String(line.dropFirst("\tprogram = ".count))
            } else if line == "\targuments = {" {
                block = "arguments"
            } else if line == "\tenvironment = {" {
                block = "environment"
            }
        }
        guard let program, let arguments, let wanted = job["ProgramArguments"] as? [String] else { return nil }
        let wantedEnvironment = job["EnvironmentVariables"] as? [String: String] ?? [:]
        if environment == nil && !wantedEnvironment.isEmpty { return nil }
        let loadedEnvironment = (environment ?? [:]).filter {
            !launchdEnvironment.contains($0.key) && !$0.key.hasPrefix("XPC_")
        }
        return program == (job["Program"] as? String ?? wanted.first) && arguments == wanted
            && loadedEnvironment == wantedEnvironment
    }

    private func lock() throws -> Int32 {
        let fd = open(root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open local server installation lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Failure("Another Tilr is installing the server. Try again shortly.")
        }
        return fd
    }

    /// Our plist, parsed; nil when there is none; throws when the file is not ours.
    private func ownPlist() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        guard let old = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              Self.isOwnJob(old, label: label, binary: binary) else {
            throw Failure("\(plist.path) is not Tilr's local server service. It was left untouched.")
        }
        return old
    }

    /// The live panes of the running server: `tilrd ps` sends ListPanes over the server's
    /// WebSocket with the stored token and prints a header and one line per pane. nil when the
    /// server does not answer; callers treat that as busy.
    func livePanes() -> Int? {
        if let paneCount { return paneCount() }
        guard let list = try? command(binary, ["ps", "--url", endpoint]), list.status == 0 else { return nil }
        return max(0, list.text.split(separator: "\n").count - 1)
    }

    /// Loads our plist; a job that is loaded but has no process (launchd sometimes holds a
    /// RunAtLoad job back) is started. Clears a pending restart: launchd now runs the file.
    func bootstrapJob() throws {
        progress?("Loading the local server service…")
        var result = try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        // A job just booted out may still be tearing down (EIO); give it a moment.
        let deadline = Date().addingTimeInterval(timeout)
        while result.status != 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if try launchctl(["print", service]).status == 0 { result = Output(status: 0, text: ""); break }
            result = try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
        }
        guard result.status == 0 else { throw Failure("Cannot load the local server service: \(result.text)") }
        try? FileManager.default.removeItem(at: restartMarker)
        let loaded = try launchctl(["print", service])
        let hasProcess = loaded.text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ")
        }
        if loaded.status == 0 && !hasProcess {
            progress?("Starting the local server…")
            let kick = try launchctl(["kickstart", service])
            guard kick.status == 0 else { throw Failure("Cannot start the local server: \(kick.text)") }
        }
    }

    /// Restart with the plist's definition: bootout (open panes close) and bootstrap.
    func restart() throws {
        let fd = try lock()
        defer { flock(fd, LOCK_UN); close(fd) }
        guard try ownPlist() != nil else { throw Failure("The local server is not installed.") }
        if try launchctl(["print", service]).status == 0 {
            progress?("Stopping the local server…")
            let result = try launchctl(["bootout", service])
            guard result.status == 0 else { throw Failure("Cannot stop the local server: \(result.text)") }
        }
        try bootstrapJob()
    }

    enum Removal { case removed, notInstalled }

    /// Takes away what the app installed: the job (bootout, so launchd and Login Items forget it),
    /// its plist, the binary, receipts, origins and runtime. `state/` (sessions, token, logs) and
    /// server.log stay. Another program's plist or a loaded job without our file is left alone.
    func remove() throws -> Removal {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) || fm.fileExists(atPath: plist.path) else { return .notInstalled }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = try lock()
        defer { flock(fd, LOCK_UN); close(fd) }
        let ours = try ownPlist() != nil
        let loaded = try launchctl(["print", service]).status == 0
        if !ours && loaded {
            throw Failure("A service named \(label) is loaded without Tilr's file \(plist.path). It was left untouched.")
        }
        guard ours || fm.fileExists(atPath: receipt.path) else { return .notInstalled }
        if loaded {
            progress?("Stopping the local server…")
            let result = try launchctl(["bootout", service])
            let gone = try launchctl(["print", service]).status != 0
            guard result.status == 0 || gone else {
                throw Failure("Cannot stop the local server: \(result.text)")
            }
        }
        progress?("Removing the local server…")
        if ours { try fm.removeItem(at: plist) }
        let names = ["tilrd", "tilrd.previous", "app-managed.json", "app-managed.previous.json",
                     "pending-server.json", "origins.toml", "runtime", "restart-pending"]
        for name in names { try? fm.removeItem(at: root.appendingPathComponent(name)) }
        for file in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("tilrd.new.") {
            try? fm.removeItem(at: file)
        }
        guard !fm.fileExists(atPath: binary.path), !fm.fileExists(atPath: receipt.path) else {
            throw Failure("Cannot delete the installed server in \(root.path).")
        }
        return .removed
    }

    func checkPort() throws {
        if let portCheck { return try portCheck() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("Cannot check the local server port") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            if errno != EADDRINUSE { throw Failure("Cannot check the local server port: \(String(cString: strerror(errno)))") }
            throw Failure("Port \(port) is already in use. The existing server was left untouched. Choose another local_server.port in Tilr's config, or stop the separate server yourself.")
        }
    }

    func credentials() throws -> [String: String] {
        let token = try command(binary, ["token"])
        guard token.status == 0, !token.text.isEmpty else { throw Failure("Cannot read the local server token") }
        return ["url": endpoint, "token": token.text]
    }
}
