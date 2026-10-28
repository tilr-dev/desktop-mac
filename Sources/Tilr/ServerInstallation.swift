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
    var timeout: TimeInterval
    let origins: [String]
    let appBuild: Int
    let protocolVersion: Int
    let architecture: String
    var runner: Runner? = nil
    var sourceManifest: URL? = nil
    /// Each launchd step, for the status the app shows while it works.
    var progress: ((String) -> Void)? = nil

    /// Selection is shared with the UI across its background preparation operation.
    final class Selection {
        var binary: URL?
        var found = false
        var helper: URL?
    }
    var selection = Selection()
    var loginShell: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    var socketPath: String = ServerInstallation.defaultSocket
    var runningExecutable: (() throws -> URL?)? = nil

    static var defaultSocket: String {
        let env = ProcessInfo.processInfo.environment
        if let socket = env["TILR_SOCKET"], !socket.isEmpty { return socket }
        let directory: URL
        if let runtime = env["TILR_RUNTIME_DIR"], !runtime.isEmpty {
            directory = URL(fileURLWithPath: runtime)
        } else if let runtime = env["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            directory = URL(fileURLWithPath: runtime).appendingPathComponent("tilr")
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-\(geteuid())")
        }
        return directory.appendingPathComponent("tilrd.sock").path
    }
    var binary: URL { selection.binary ?? root.appendingPathComponent("tilrd") }
    var receipt: URL { root.appendingPathComponent(".tilr-app-server.json") }
    var installationMarker: URL { root.appendingPathComponent(".tilr-app-installed") }
    var plist: URL { agents.appendingPathComponent(label + ".plist") }
    var endpoint: String { "ws://127.0.0.1:7890" }
    var service: String { "gui/\(getuid())/sh.tilr.tilrd" }
    var state: URL {
        let env = ProcessInfo.processInfo.environment
        if let state = env["TILR_STATE_DIR"], !state.isEmpty { return URL(fileURLWithPath: state) }
        if let state = env["XDG_STATE_HOME"], !state.isEmpty { return URL(fileURLWithPath: state).appendingPathComponent("tilr") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/tilr")
    }
    var isInstalled: Bool { selection.found || FileManager.default.isExecutableFile(atPath: binary.path) }
    var installedByApp: Bool {
        guard !selection.found || selection.binary != nil else { return false }
        guard let path = try? String(contentsOf: installationMarker, encoding: .utf8), !path.isEmpty else { return false }
        let expected = root.appendingPathComponent("tilrd").resolvingSymlinksInPath()
        return URL(fileURLWithPath: path).resolvingSymlinksInPath() == expected
            && binary.resolvingSymlinksInPath() == expected
    }
    // The app's bundled CLI carries its supported protocol. An installed CLI could accept a
    // newer daemon that this app cannot speak to, so it must not validate app compatibility.
    var client: URL { selection.helper ?? source.appendingPathComponent("tilr") }

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
        // Use the ordinary CLI defaults, including user state and runtime configuration.
        process.environment = ProcessInfo.processInfo.environment
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
        var observedVersion: String?
        repeat {
            if let current = try runningVersion() {
                observedVersion = current
                if version == nil || current == version { return try credentials() }
            }
            wait(retryInterval)
        } while now() < deadline
        let mismatch: String
        if let version, let runningVersion = observedVersion {
            mismatch = " Reload did not complete: running version \(runningVersion), expected \(version)."
        } else {
            mismatch = ""
        }
        throw Failure("The local server did not become ready.\(mismatch) See ~/Library/Logs/tilrd.log. Existing processes were not stopped.")
    }

    func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// `version` authenticates the local socket without starting a daemon. The bundled client
    /// performs the ordinary protocol and peer checks before any installation is considered.
    func runningVersion() throws -> String? {
        let response = try command(client, ["--socket", socketPath, "version"])
        guard response.status == 0 else {
            let hint = response.text.lowercased().contains("protocol") ? " Update tilrd in Local Server." : ""
            throw Failure("Cannot connect to the ordinary tilrd: \(response.text)\(hint)")
        }
        for line in response.text.split(separator: "\n") {
            if line.hasPrefix("tilrd "), !line.hasPrefix("tilrd is not running at "), let end = line.range(of: " at ") {
                let value = String(line[line.index(line.startIndex, offsetBy: 6)..<end.lowerBound])
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// macOS exposes the connected peer's pid. Resolve the live daemon's path for explicit
    /// replacement; startup itself never needs to search PATH after a successful socket probe.
    private func socketExecutable() -> URL? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: path))
        return executable.lastPathComponent == "tilrd" ? executable : nil
    }

    private func executableVersion(_ url: URL) throws -> String {
        let response = try command(url, ["--version"])
        guard response.status == 0, response.text.hasPrefix("tilrd "),
              let end = response.text.range(of: " (") else { throw Failure("Invalid installed tilrd: \(response.text)") }
        return String(response.text[response.text.index(response.text.startIndex, offsetBy: 6)..<end.lowerBound])
    }

    private func installedManifest(version: String) throws -> Manifest {
        if let data = try? Data(contentsOf: receipt),
           let saved = try? JSONDecoder().decode(Manifest.self, from: data),
           saved.serverVersion == version, (try? hash(binary)) == saved.sha256 {
            return saved
        }
        // An ordinary installation has no application feed build number or receipt.
        return Manifest(version: version, build: 0, arch: architecture, serverVersion: version,
                        sha256: (try? hash(binary)) ?? "", protocolVersion: protocolVersion,
                        minAppBuild: 0, maxAppBuild: nil)
    }

    private func discover(start: Bool = true) throws -> Manifest? {
        if selection.helper == nil { selection.helper = source.appendingPathComponent("tilr") }
        let running: String?
        do { running = try runningVersion() }
        catch {
            // Keep the socket peer selected for explicit recovery even when the bundled
            // client refuses its protocol. Never fall through to installing another daemon.
            selection.binary = try runningExecutable?() ?? socketExecutable()
            selection.found = true
            throw error
        }
        if let version = running {
            if selection.binary == nil {
                selection.binary = try runningExecutable?() ?? socketExecutable()
            }
            selection.found = true
            return try installedManifest(version: version)
        }
        let path = try command(loginShell, ["-lc", "command -v tilrd"])
        var candidate: URL?
        if path.status == 0, path.text.hasPrefix("/"), !path.text.contains("\n") {
            candidate = URL(fileURLWithPath: path.text)
        } else if FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("tilrd").path) {
            candidate = root.appendingPathComponent("tilrd")
        }
        guard let candidate else { return nil }
        selection.binary = candidate
        let version = try executableVersion(candidate)
        selection.found = true
        if start { try startService() }
        return try installedManifest(version: version)
    }

    /// Uninstall must also work with integration disabled, without starting or installing anything.
    func locateForRemoval() throws { _ = try discover(start: false) }

    /// A bundled CLI beside its own daemon would select that daemon before PATH. If an external
    /// installation lacks a sibling CLI, a private temporary pair points the helper at that exact
    /// daemon; service install canonicalizes the symlink into the ordinary service definition.
    private func startService() throws {
        progress?("Starting the ordinary tilrd service…")
        let sibling = binary.deletingLastPathComponent().appendingPathComponent("tilr")
        let response: Output
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            response = try command(sibling, ["--socket", socketPath, "service", "install"])
        } else {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-cli-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temp) }
            try FileManager.default.copyItem(at: (selection.helper ?? source.appendingPathComponent("tilr")), to: temp.appendingPathComponent("tilr"))
            try FileManager.default.createSymbolicLink(at: temp.appendingPathComponent("tilrd"), withDestinationURL: binary)
            response = try command(temp.appendingPathComponent("tilr"), ["--socket", socketPath, "service", "install"])
        }
        guard response.status == 0 else { throw Failure("Cannot start tilrd service: \(response.text)") }
    }

    /// The bundle is used only for an absent installation. The durable journal belongs
    /// solely to offline bootstrap; installed daemons own their updates.
    func install() throws -> Manifest {
        let fm = FileManager.default
        let pending = root.appendingPathComponent(".tilr-app-pending.json")
        let hasPending = fm.fileExists(atPath: pending.path)
        if hasPending, let data = try? Data(contentsOf: pending),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = object["binaryPath"] as? String {
            selection.binary = URL(fileURLWithPath: path)
        }
        if !hasPending, let found = try discover() { return found }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Lock the stable directory inode: removal can clean the old lock file without
        // allowing another installer to acquire a different lock inode concurrently.
        let fd = open(root.path, O_RDONLY)
        guard fd >= 0 else { throw Failure("Cannot lock the tilrd installation") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure("Cannot lock the tilrd installation") }
        if !hasPending, let found = try discover() { return found }
        if fm.fileExists(atPath: pending.path) {
            let data = try Data(contentsOf: pending)
            let saved = try JSONDecoder().decode(Manifest.self, from: data)
            let transaction = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if transaction["bootstrap"] as? Bool == true {
                return try finishTransaction(saved, transaction: transaction, pending: pending)
            }
            // Retire an obsolete app-update journal without publishing its stage or
            // reloading a live daemon. The installed executable remains authoritative.
            try fm.removeItem(at: pending)
            try? fm.removeItem(at: binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new"))
            if let found = try discover() { return found }
        }
        let data = try Data(contentsOf: sourceManifest ?? source.appendingPathComponent("app-managed.json"))
        let wanted = try JSONDecoder().decode(Manifest.self, from: data)
        let payload = source.appendingPathComponent("tilrd")
        guard wanted.supports(appBuild: appBuild, protocolVersion: protocolVersion, arch: architecture) else {
            throw Failure("The server is incompatible with this application; the running daemon was left untouched.")
        }
        guard try hash(payload) == wanted.sha256 else { throw Failure("Server checksum mismatch") }
        let signature = try command(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", payload.path])
        guard signature.status == 0, try executableVersion(payload) == wanted.serverVersion else {
            throw Failure("Server signature or version verification failed")
        }
        let cli = source.appendingPathComponent("tilr")
        let check = try command(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", cli.path])
        let version = try command(cli, ["--version"])
        guard check.status == 0, version.status == 0,
              version.text.hasPrefix("tilr \(wanted.serverVersion) (") else { throw Failure("Bundled client does not match the daemon") }
        guard !fm.fileExists(atPath: root.appendingPathComponent("tilr").path),
              !fm.fileExists(atPath: binary.path) else { throw Failure("An existing installation was left untouched") }
        // Both stages and their durable journal precede either executable's publication.
        let staged = binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new")
        let stagedClient = root.appendingPathComponent(".tilr.app-new")
        // Stages left before journal creation have never been published and can be replaced.
        for file in [staged, stagedClient] where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        defer {
            if !fm.fileExists(atPath: pending.path) {
                try? fm.removeItem(at: staged)
                try? fm.removeItem(at: stagedClient)
            }
        }
        try fm.copyItem(at: payload, to: staged)
        try fm.copyItem(at: source.appendingPathComponent("tilr"), to: stagedClient)
        var transaction = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        transaction["binaryPath"] = binary.path
        transaction["bootstrap"] = true
        transaction["clientHash"] = try hash(stagedClient)
        try JSONSerialization.data(withJSONObject: transaction).write(to: pending, options: .atomic)
        return try finishTransaction(wanted, transaction: transaction, pending: pending)
    }

    /// A journal is committed only after both stages exist. Each rename and marker write can
    /// be replayed after process termination, including a stop between the two pair renames.
    private func finishTransaction(_ wanted: Manifest, transaction: [String: Any], pending: URL) throws -> Manifest {
        let fm = FileManager.default
        guard transaction["bootstrap"] as? Bool == true else {
            throw Failure("An old application update transaction remains. Use tilrd update to recover; the daemon was left untouched.")
        }
        let staged = binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new")
        let stagedClient = root.appendingPathComponent(".tilr.app-new")
        do {
            let installedClient = root.appendingPathComponent("tilr")
            guard let clientHash = transaction["clientHash"] as? String else { throw Failure("Invalid bootstrap transaction") }
            if (try? hash(installedClient)) != clientHash {
                guard !fm.fileExists(atPath: installedClient.path), try hash(stagedClient) == clientHash,
                      rename(stagedClient.path, installedClient.path) == 0 else {
                    throw Failure("Cannot complete the installed tilr client")
                }
            }
        }
        if (try? hash(binary)) != wanted.sha256 {
            guard try hash(staged) == wanted.sha256,
                  rename(staged.path, binary.path) == 0 else { throw Failure("Cannot replace installed tilrd") }
        }
        try JSONEncoder().encode(wanted).write(to: receipt, options: .atomic)
        try Data(binary.path.utf8).write(to: installationMarker, options: .atomic)
        selection.binary = binary
        selection.found = true
        if try runningVersion() == nil { try startService() }
        try fm.removeItem(at: pending)
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: stagedClient)
        return wanted
    }

    func installedVersion() throws -> String {
        guard isInstalled, !selection.found || selection.binary != nil else {
            throw Failure("Cannot determine the installed tilrd executable; it was left untouched.")
        }
        return try executableVersion(binary)
    }

    /// Delegate all download and publication work to the selected ordinary daemon.
    func update(channel: String) throws -> String {
        guard ["stable", "beta"].contains(channel) else { throw Failure("Invalid tilrd update channel") }
        _ = try installedVersion()
        progress?("Updating tilrd (\(channel))…")
        let response = try command(binary, ["update", "--channel", channel])
        guard response.status == 0 else { throw Failure("tilrd update failed: \(response.text)") }
        return try installedVersion()
    }

    /// Commit suffixes identify a build, not release order. RC versions sort below
    /// their stable release; compare numeric RC identifiers numerically.
    static func isOlder(_ version: String, than pin: String) -> Bool {
        func parts(_ value: String) -> ([Int], String?) {
            let clean = value.split(separator: "+", maxSplits: 1)[0]
            let pieces = clean.split(separator: "-", maxSplits: 1)
            let numbers = pieces[0].split(separator: ".").compactMap { Int($0) }
            let suffix = pieces.count > 1 ? String(pieces[1].split(separator: "-")[0]) : ""
            return (numbers, suffix.hasPrefix("rc") || suffix.hasPrefix("beta") || suffix.hasPrefix("alpha") ? suffix : nil)
        }
        let (left, prerelease) = parts(version)
        let (right, pinnedPrerelease) = parts(pin)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        if let prerelease, let pinnedPrerelease {
            return prerelease.compare(pinnedPrerelease, options: .numeric) == .orderedAscending
        }
        return prerelease != nil && pinnedPrerelease == nil
    }

    enum Removal { case removed, notInstalled, declined }
    func remove(confirmExternal: () throws -> Bool = { false }) throws -> Removal {
        let owned = installedByApp
        guard isInstalled || owned else { return .notInstalled }
        guard !selection.found || selection.binary != nil else {
            throw Failure("Cannot determine the running tilrd executable; it was left untouched.")
        }
        guard owned || FileManager.default.fileExists(atPath: binary.path) else {
            throw Failure("Cannot locate the installed tilrd executable for removal.")
        }
        if !owned, try !confirmExternal() { return .declined }
        // Serialize application-owned pair changes. Refusing an external removal creates no lock.
        let lock = root.appendingPathComponent(".tilr-app-install.lock")
        let fd = owned ? open(root.path, O_RDONLY) : -1
        if owned {
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else {
                if fd >= 0 { close(fd) }
                throw Failure("Cannot lock the tilrd installation")
            }
        }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        guard !owned || installedByApp else { throw Failure("The tilrd installation changed during removal. Try again.") }
        let result = try command(client, ["service", "uninstall"])
        guard result.status == 0 else { throw Failure("Cannot uninstall tilrd service: \(result.text)") }
        let transactionFiles = [root.appendingPathComponent(".tilr-app-pending.json"),
                                binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new"),
                                root.appendingPathComponent(".tilr.app-new"),
                                root.appendingPathComponent(".tilr-app-server.previous.json"),
                                binary.appendingPathExtension("previous")]
        let files = owned
            ? [lock] + transactionFiles + [root.appendingPathComponent("tilr"), receipt, binary, installationMarker]
            : [binary]
        for file in files {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        selection.found = false
        selection.binary = nil
        return .removed
    }

    func credentials() throws -> [String: String] {
        let token = try command(client, ["--socket", socketPath, "token"])
        guard token.status == 0, !token.text.isEmpty else { throw Failure("Cannot read the local server token: \(token.text)") }
        return ["url": endpoint, "token": token.text]
    }
}
