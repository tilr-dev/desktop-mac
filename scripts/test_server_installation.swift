import Foundation
import CryptoKit
import Darwin

@main struct InstallationTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("tilr-install-test-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        func expect(_ condition: Bool, line: UInt = #line) { precondition(condition, "line \(line)") }
        func rejects(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected refusal") } catch {}
        }
        func executable(_ url: URL, _ script: String) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("#!/bin/sh\nset -eu\n" + script).utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        func fixture(_ name: String) throws -> ServerInstallation {
            let base = temp.appendingPathComponent(name)
            let source = base.appendingPathComponent("bundle")
            let root = base.appendingPathComponent("bin")
            let log = base.appendingPathComponent("commands")
            let running = base.appendingPathComponent("running")
            let path = base.appendingPathComponent("path")
            // These are executable process stubs, with explicit state transitions, no sleeps.
            try executable(source.appendingPathComponent("tilrd"), "echo 'tilrd 1.0.0-abc (macos-aarch64)'\n")
            try executable(source.appendingPathComponent("tilr"), """
            echo "$0 $*" >> '\(log.path)'
            if [ "$1" = '--version' ]; then echo 'tilr 1.0.0-abc (macos-aarch64)'; exit; fi
            if [ "$1" = '--socket' ]; then shift 2; fi
            case "$1" in
            version)
                echo 'tilr 1.0.0-abc (macos-aarch64)'
                if [ -f '\(running.path)' ]; then echo "tilrd $(cat '\(running.path)') at local"; else echo 'tilrd is not running at local'; fi ;;
            token) test -f '\(running.path)'; echo shared-token ;;
            service) if [ "$2" = install ]; then echo 1.0.0-abc > '\(running.path)'; fi ;;
            *) exit 1 ;;
            esac
            """)
            let bytes = try Data(contentsOf: source.appendingPathComponent("tilrd"))
            let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let manifest = ServerInstallation.Manifest(version: "1.0.0", build: 1, arch: "arm64", serverVersion: "1.0.0-abc", sha256: sha, protocolVersion: 1, minAppBuild: 1, maxAppBuild: nil)
            try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("app-managed.json"))
            var install = ServerInstallation(source: source, root: root, agents: base.appendingPathComponent("agents"), label: "sh.tilr.tilrd", port: 7890, timeout: 5, origins: ["tilr://app"], appBuild: 10, protocolVersion: 1, architecture: "arm64")
            try executable(base.appendingPathComponent("shell"), """
            echo shell >> '\(log.path)'
            if [ -f '\(path.path)' ]; then cat '\(path.path)'; else exit 1; fi
            """)
            install.loginShell = base.appendingPathComponent("shell")
            install.socketPath = base.appendingPathComponent("socket").path
            let processInstall = install
            install.runner = { url, args in
                if url.lastPathComponent == "codesign" { return .init(status: 0, text: "") }
                return try processInstall.command(url, args)
            }
            return install
        }
        func base(_ install: ServerInstallation) -> URL { install.root.deletingLastPathComponent() }
        func commands(_ install: ServerInstallation) -> String {
            (try? String(contentsOf: base(install).appendingPathComponent("commands"), encoding: .utf8)) ?? ""
        }
        // Running socket wins, even over a PATH candidate and a local installation. No writes.
        let running = try fixture("running")
        try Data("2.0.0-new\n".utf8).write(to: base(running).appendingPathComponent("running"))
        try Data("/unused/path/tilrd\n".utf8).write(to: base(running).appendingPathComponent("path"))
        let found = try running.install()
        expect(found.serverVersion == "2.0.0-new")
        expect(!commands(running).contains("shell"))
        expect(!commands(running).contains("service install"))
        expect(!fm.fileExists(atPath: running.root.path))
        expect(try running.credentials() == ["url": "ws://127.0.0.1:7890", "token": "shared-token"])
        expect(try running.remove() == .notInstalled)
        // Login PATH wins over ~/.local/bin, including a tilrd without a sibling client.
        let path = try fixture("path")
        let external = base(path).appendingPathComponent("external/tilrd")
        try executable(external, "echo 'tilrd 1.0.0-abc (macos-aarch64)'\n")
        try Data((external.path + "\n").utf8).write(to: base(path).appendingPathComponent("path"))
        try executable(path.root.appendingPathComponent("tilrd"), "echo 'tilrd 9.0 (macos-aarch64)'\n")
        let original = try Data(contentsOf: path.root.appendingPathComponent("tilrd"))
        _ = try path.install()
        expect(path.binary == external)
        expect(commands(path).contains("service install"))
        expect(try Data(contentsOf: path.root.appendingPathComponent("tilrd")) == original)
        expect(!path.installedByApp)
        expect(!fm.fileExists(atPath: path.receipt.path))
        // Local-bin fallback preserves the pre-existing pair and does not claim ownership.
        let local = try fixture("local")
        try fm.createDirectory(at: local.root, withIntermediateDirectories: true)
        for name in ["tilrd", "tilr"] { try fm.copyItem(at: local.source.appendingPathComponent(name), to: local.root.appendingPathComponent(name)) }
        _ = try local.install()
        expect(local.binary == local.root.appendingPathComponent("tilrd"))
        expect(!local.installedByApp)
        expect(try local.credentials()["token"] == "shared-token")
        // Offline install copies the exact pair, uses service install and records ownership.
        let absent = try fixture("absent")
        let installed = try absent.install()
        expect(installed.build == 1 && absent.installedByApp)
        for name in ["tilrd", "tilr"] {
            expect(try Data(contentsOf: absent.source.appendingPathComponent(name)) == Data(contentsOf: absent.root.appendingPathComponent(name)))
        }
        expect(commands(absent).contains("service install"))
        expect(!fm.fileExists(atPath: absent.plist.path))
        expect(!fm.fileExists(atPath: absent.root.appendingPathComponent("state").path))
        expect(!fm.fileExists(atPath: absent.root.appendingPathComponent("app-managed.json").path))
        let credentials = try absent.waitReady(version: installed.serverVersion, startupTimeout: 1, retryInterval: 1, wait: { _ in fatalError("Already ready") })
        let cliToken = try absent.command(absent.root.appendingPathComponent("tilr"), ["--socket", absent.socketPath, "token"])
        expect(credentials["token"] == cliToken.text)
        let before = try Data(contentsOf: absent.binary)
        _ = try absent.install()
        expect(try Data(contentsOf: absent.binary) == before)
        // Explicit updates keep reload transactions pending on failure and recover on launch.
        let updatedSource = base(absent).appendingPathComponent("update")
        try fm.createDirectory(at: updatedSource, withIntermediateDirectories: true)
        let updateBytes = Data("#!/bin/sh\necho 'tilrd 1.1.0-new (macos-aarch64)'\n".utf8)
        try updateBytes.write(to: updatedSource.appendingPathComponent("tilrd"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updatedSource.appendingPathComponent("tilrd").path)
        let updateHash = SHA256.hash(data: updateBytes).map { String(format: "%02x", $0) }.joined()
        let updated = ServerInstallation.Manifest(version: "1.1.0", build: 2, arch: "arm64", serverVersion: "1.1.0-new", sha256: updateHash, protocolVersion: 1, minAppBuild: 1, maxAppBuild: nil)
        try JSONEncoder().encode(updated).write(to: updatedSource.appendingPathComponent("app-managed.json"))
        var update = ServerInstallation(source: updatedSource, root: absent.root, agents: absent.agents, label: absent.label, port: 7890, timeout: 5, origins: [], appBuild: 10, protocolVersion: 1, architecture: "arm64")
        update.selection = absent.selection
        update.socketPath = absent.socketPath
        update.updateRequested = true
        var reloadStatus: Int32 = 1
        let realRunner = absent.runner!
        update.runner = { url, args in
            if url.lastPathComponent == "launchctl" {
                expect(args == ["kill", "SIGUSR1", update.service])
                return .init(status: reloadStatus, text: "reload failed")
            }
            return try realRunner(url, args)
        }
        rejects { _ = try update.install() }
        expect(try Data(contentsOf: absent.binary) == updateBytes)
        expect(try Data(contentsOf: absent.binary.appendingPathExtension("previous")) == before)
        let pending = absent.root.appendingPathComponent(".tilr-app-pending.json")
        expect(fm.fileExists(atPath: pending.path))
        reloadStatus = 0
        var resume = absent
        resume.runner = update.runner
        expect(try resume.install().build == 2)
        expect(!fm.fileExists(atPath: pending.path))
        // A successful reload request is not readiness until the server reports the new version.
        try Data("1.1.0-new\n".utf8).write(to: base(absent).appendingPathComponent("running"))
        expect(try absent.waitReady(version: updated.serverVersion, startupTimeout: 1, retryInterval: 1, wait: { _ in fatalError("Already ready") })["token"] == "shared-token")
        // Failed signatures and mismatched clients cannot expose a partial pair.
        var unsigned = try fixture("unsigned")
        let previousRunner = unsigned.runner!
        unsigned.runner = { url, args in
            if url.lastPathComponent == "codesign" { return .init(status: 1, text: "unsigned") }
            return try previousRunner(url, args)
        }
        rejects { _ = try unsigned.install() }
        expect(!fm.fileExists(atPath: unsigned.binary.path))
        let mismatch = try fixture("mismatch")
        try executable(mismatch.source.appendingPathComponent("tilr"), "if [ \"$1\" = --version ]; then echo 'tilr wrong (macos-aarch64)'; else echo 'tilrd is not running at local'; fi\n")
        rejects { _ = try mismatch.install() }
        expect(!fm.fileExists(atPath: mismatch.binary.path))
        // A protocol/peer failure must not be treated as an absent server and overwritten.
        var incompatible = try fixture("incompatible")
        incompatible.runner = { _, _ in .init(status: 1, text: "incompatible protocol") }
        rejects { _ = try incompatible.install() }
        expect(!fm.fileExists(atPath: incompatible.root.path))
        // Existing tilr alone is not silently overwritten.
        let clientOnly = try fixture("client-only")
        try executable(clientOnly.root.appendingPathComponent("tilr"), "exit 0\n")
        rejects { _ = try clientOnly.install() }
        expect(!fm.fileExists(atPath: clientOnly.binary.path))
        // Deterministic readiness mismatch retains running sessions and reports both versions.
        var time = Date(timeIntervalSince1970: 0)
        do {
            _ = try running.waitReady(version: "3.0.0", startupTimeout: 2, retryInterval: 1, now: { time }, wait: { time.addTimeInterval($0) })
            fatalError("Expected mismatch")
        } catch {
            expect(error.localizedDescription.contains("2.0.0-new") && error.localizedDescription.contains("3.0.0"))
        }
        print("ordinary tilrd installation tests passed")
    }
}
