import Foundation
import CryptoKit
import Darwin

/// A stable executable outside .app, seeded by the bundle and independently updated.
/// An app upgrade retains a newer compatible installed server. launchd and the server's reload watcher keep
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

    var binary: URL { root.appendingPathComponent("tilr-server") }
    var receipt: URL { root.appendingPathComponent("app-managed.json") }
    var plist: URL { agents.appendingPathComponent(label + ".plist") }
    var endpoint: String { "ws://127.0.0.1:\(port)" }
    var service: String { "gui/\(getuid())/\(label)" }
    var state: URL { root.appendingPathComponent("state") }

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
        let fd = open(root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open local server installation lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another Tilr is installing the server. Try again shortly.") }
        defer { flock(fd, LOCK_UN) }

        // Recover the binary/receipt transaction before comparing against an older bundle.
        // Before rename: keep the old receipt. After rename: finish the new receipt.
        let pending = root.appendingPathComponent("pending-server.json")
        if fm.fileExists(atPath: pending.path) {
            let pendingData = try Data(contentsOf: pending)
            let incoming = try JSONDecoder().decode(Manifest.self, from: pendingData)
            if (try? hash(binary)) == incoming.sha256 {
                try pendingData.write(to: receipt, options: .atomic)
            }
            try fm.removeItem(at: pending)
        }
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("tilr-server.new.") {
            try fm.removeItem(at: file)
        }

        var data = try Data(contentsOf: sourceManifest ?? source.appendingPathComponent("app-managed.json"))
        var wanted = try JSONDecoder().decode(Manifest.self, from: data)
        var payload = source.appendingPathComponent("tilr-server")
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
        guard version.status == 0, version.text.hasPrefix("tilr-server \(wanted.serverVersion) (") else {
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
        ]
        let jobState = try launchctl(["print", service])
        var loaded = jobState.status == 0
        let running = loaded && jobState.text.contains("state = running")
        // An earlier Tilr's job, the server started through `/bin/zsh -lc`: rewritten, not refused.
        var migrate = false
        if fm.fileExists(atPath: plist.path) {
            let old = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
            if let old = old as? NSDictionary, old.isEqual(to: job) {
            } else if let old = old as? [String: Any], Self.isShellWrapped(old, wanted: job, binary: binary) {
                migrate = true
            } else {
                throw Failure("Local server service settings changed. The running service was left untouched: \(plist.path)")
            }
        } else if loaded {
            throw Failure("A service with the same name already exists. It was left untouched.")
        }
        // A separately installed server (or another application) may own this port.
        if !loaded { try checkPort() }

        let needsCopy = (try? hash(binary)) != wanted.sha256
        let configFile = root.appendingPathComponent("origins.toml")
        let encodedOrigins = String(decoding: try JSONSerialization.data(withJSONObject: origins.sorted(), options: [.withoutEscapingSlashes]), as: UTF8.self)
        let configData = Data(("# Managed by Tilr.app; regenerated at launch.\nallow_origins = " + encodedOrigins + "\n").utf8)
        let configChanged = (try? Data(contentsOf: configFile)) != configData
        if needsCopy {
            if loaded && jobState.text.contains("state = running"), existing != nil && fm.fileExists(atPath: binary.path) {
                let old = try command(binary, ["state-formats"])
                let new = try command(payload, ["state-formats"])
                guard old.status == 0, new.status == 0, !old.text.isEmpty, old.text == new.text else {
                    throw Failure("This server update needs a session migration. Existing terminals were left running.")
                }
            }
            let staged = root.appendingPathComponent("tilr-server.new.\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: payload, to: staged)
            if fm.fileExists(atPath: binary.path) {
                let previous = root.appendingPathComponent("tilr-server.previous")
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
            try fm.removeItem(at: pending)
        }
        if !needsCopy && configChanged { try configData.write(to: configFile, options: .atomic) }
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        if migrate && loaded && !running {
            // A stopped job has no terminals to lose: replace its definition now.
            let result = try launchctl(["bootout", service])
            guard result.status == 0 else { throw Failure("Cannot replace the stopped local server service: \(result.text)") }
            loaded = false
        }
        // A running migrated job keeps its terminals and its loaded definition until it is next
        // bootstrapped (the next login); launchd reads the rewritten file then.
        if migrate || !fm.fileExists(atPath: plist.path) {
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
        }
        _ = try credentials()
        if !loaded {
            let result = try launchctl(["bootstrap", "gui/\(getuid())", plist.path])
            guard result.status == 0 else { throw Failure("Cannot start the local server: \(result.text)") }
        } else if !running {
            // No -k: start a stopped job, never kill/restart an existing supervisor.
            let result = try launchctl(["kickstart", service])
            guard result.status == 0 else { throw Failure("Cannot start the local server: \(result.text)") }
        } else if configChanged && !needsCopy {
            // Reload config through the server's session-preserving path, not a restart.
            let result = try launchctl(["kill", "SIGUSR1", service])
            guard result.status == 0 else { throw Failure("Cannot reload the local server's allowed origins: \(result.text)") }
        }
        return wanted
    }

    /// Whether `old` is the job an earlier Tilr wrote for `binary`: the same as `wanted` but for
    /// ProgramArguments, which ran the binary through `/bin/zsh -lc`.
    static func isShellWrapped(_ old: [String: Any], wanted: [String: Any], binary: URL) -> Bool {
        guard let args = old["ProgramArguments"] as? [String], args.first == "/bin/zsh",
              args.dropFirst().first == "-lc", args.contains(binary.path) else { return false }
        var rest = old, wantedRest = wanted
        rest.removeValue(forKey: "ProgramArguments")
        wantedRest.removeValue(forKey: "ProgramArguments")
        return NSDictionary(dictionary: rest).isEqual(to: wantedRest)
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
