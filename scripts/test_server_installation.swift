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
        let beforeUnknownRemoval = commands(running)
        var unknownQuestions = 0
        rejects { _ = try running.remove(confirmExternal: { unknownQuestions += 1; return true }) }
        expect(unknownQuestions == 0 && commands(running) == beforeUnknownRemoval)
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
        let beforeDecline = commands(path)
        var questions = 0
        expect(try path.remove(confirmExternal: { questions += 1; return false }) == .declined)
        expect(questions == 1 && commands(path) == beforeDecline)
        expect(fm.fileExists(atPath: external.path))
        expect(!fm.fileExists(atPath: path.root.appendingPathComponent(".tilr-app-install.lock").path))
        expect(try path.remove(confirmExternal: { questions += 1; return true }) == .removed)
        expect(questions == 2 && !fm.fileExists(atPath: external.path))
        expect(try Data(contentsOf: path.root.appendingPathComponent("tilrd")) == original)
        expect(commands(path).contains("service uninstall"))
        // A selected external executable can disappear before the user requests removal.
        let missing = try fixture("missing-removal")
        try executable(missing.root.appendingPathComponent("tilrd"), "echo 'tilrd 1.0.0-abc (macos-aarch64)'\n")
        try missing.locateForRemoval()
        try fm.removeItem(at: missing.binary)
        let beforeMissingRemoval = commands(missing)
        var missingQuestions = 0
        rejects { _ = try missing.remove(confirmExternal: { missingQuestions += 1; return true }) }
        expect(missingQuestions == 0 && commands(missing) == beforeMissingRemoval)
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
        // The daemon owns updates, including the exact external executable selected at discovery.
        let updater = try fixture("daemon-update")
        let updateRoot = base(updater)
        let externalUpdater = updateRoot.appendingPathComponent("external/tilrd")
        let updateVersion = updateRoot.appendingPathComponent("installed-version")
        let updateFailure = updateRoot.appendingPathComponent("fail-update")
        let updateLog = updateRoot.appendingPathComponent("update-commands")
        try Data("0.9.0-old\n".utf8).write(to: updateVersion)
        try executable(externalUpdater, """
        if [ "$1" = --version ]; then echo "tilrd $(cat '\(updateVersion.path)') (macos-aarch64)"; exit; fi
        echo "$0 $*" >> '\(updateLog.path)'
        test "$#" = 3
        test "$1" = update
        test "$2" = --channel
        if [ -f '\(updateFailure.path)' ]; then echo 'download rejected by daemon' >&2; exit 7; fi
        case "$3" in
        stable) echo 0.9.1-stable > '\(updateVersion.path)' ;;
        beta) echo 1.1.0-rc.2 > '\(updateVersion.path)' ;;
        *) exit 9 ;;
        esac
        """)
        try Data((externalUpdater.path + "\n").utf8).write(to: updateRoot.appendingPathComponent("path"))
        _ = try updater.install()
        expect(updater.binary == externalUpdater)
        expect(try updater.installedVersion() == "0.9.0-old")
        let externalBytes = try Data(contentsOf: externalUpdater)
        let updateCredentials = try updater.credentials()
        try Data().write(to: updateFailure)
        do {
            _ = try updater.update(channel: "stable")
            fatalError("Expected daemon update failure")
        } catch {
            expect(error.localizedDescription.contains("download rejected by daemon"))
        }
        expect(try Data(contentsOf: externalUpdater) == externalBytes)
        expect(try updater.installedVersion() == "0.9.0-old")
        expect(try updater.credentials() == updateCredentials)
        try fm.removeItem(at: updateFailure)
        let beforeUpdateCommands = commands(updater)
        // Successful updates may still be below the bundle pin; report the actual installed version.
        let stableVersion = try updater.update(channel: "stable")
        expect(stableVersion == "0.9.1-stable")
        expect(ServerInstallation.isOlder(stableVersion, than: "1.0.0"))
        expect(try updater.update(channel: "beta") == "1.1.0-rc.2")
        let updateCommands = try String(contentsOf: updateLog, encoding: .utf8).split(separator: "\n").map(String.init)
        expect(updateCommands == ["\(externalUpdater.path) update --channel stable", "\(externalUpdater.path) update --channel stable", "\(externalUpdater.path) update --channel beta"])
        expect(commands(updater) == beforeUpdateCommands)
        expect(try Data(contentsOf: externalUpdater) == externalBytes)
        expect(!fm.fileExists(atPath: updater.receipt.path))
        expect(!fm.fileExists(atPath: updater.installationMarker.path))
        expect(!fm.fileExists(atPath: updater.root.appendingPathComponent(".tilr-app-pending.json").path))
        expect(!fm.fileExists(atPath: externalUpdater.appendingPathExtension("previous").path))
        expect(ServerInstallation.isOlder("1.0.0-rc.1", than: "1.0.0"))
        expect(ServerInstallation.isOlder("1.0.0-rc.2", than: "1.0.0-rc.10"))
        expect(!ServerInstallation.isOlder("1.0.0", than: "1.0.0-rc.1"))
        expect(!ServerInstallation.isOlder("1.0.0+installed", than: "1.0.0+bundled"))
        expect(!ServerInstallation.isOlder("2.0.0", than: "1.0.0"))
        // Recovery covers bootstrap after the client rename but before the daemon rename.
        let half = try fixture("half-bootstrap")
        try fm.createDirectory(at: half.root, withIntermediateDirectories: true)
        let halfManifest = try JSONDecoder().decode(ServerInstallation.Manifest.self, from: Data(contentsOf: half.source.appendingPathComponent("app-managed.json")))
        try fm.copyItem(at: half.source.appendingPathComponent("tilr"), to: half.root.appendingPathComponent("tilr"))
        try fm.copyItem(at: half.source.appendingPathComponent("tilrd"), to: half.binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new"))
        let clientHash = try half.hash(half.root.appendingPathComponent("tilr"))
        var transaction = try JSONSerialization.jsonObject(with: JSONEncoder().encode(halfManifest)) as! [String: Any]
        transaction["binaryPath"] = half.binary.path
        transaction["bootstrap"] = true
        transaction["clientHash"] = clientHash
        try JSONSerialization.data(withJSONObject: transaction).write(to: half.root.appendingPathComponent(".tilr-app-pending.json"))
        expect(try half.install().build == 1)
        expect(half.installedByApp)
        // Recovery after both renames but before ownership marker creation repairs the marker.
        try fm.removeItem(at: half.installationMarker)
        try JSONSerialization.data(withJSONObject: transaction).write(to: half.root.appendingPathComponent(".tilr-app-pending.json"))
        _ = try half.install()
        expect(half.installedByApp)
        // Owned removal clears stages and metadata left by a previous application version.
        let pending = absent.root.appendingPathComponent(".tilr-app-pending.json")
        try Data("legacy transaction".utf8).write(to: pending)
        try Data("legacy stage".utf8).write(to: absent.binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new"))
        expect(try absent.remove() == .removed)
        expect(!fm.fileExists(atPath: pending.path))
        expect(!fm.fileExists(atPath: absent.binary.deletingLastPathComponent().appendingPathComponent(".tilrd.app-new").path))
        try fm.removeItem(at: base(absent).appendingPathComponent("running"))
        expect(try absent.install().build == 1)
        expect(absent.installedByApp)
        // A daemon discovered via proc_pidpath uses a canonical path after relaunch.
        let linked = try fixture("linked-marker")
        let realBin = base(linked).appendingPathComponent("real-bin")
        try fm.createDirectory(at: realBin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linked.root, withDestinationURL: realBin)
        _ = try linked.install()
        linked.selection.binary = linked.binary.resolvingSymlinksInPath()
        expect(linked.installedByApp)
        let staleLock = linked.root.appendingPathComponent(".tilr-app-install.lock")
        try Data().write(to: staleLock)
        expect(try linked.remove(confirmExternal: { fatalError("Owned pair must not ask") }) == .removed)
        expect(!fm.fileExists(atPath: staleLock.path))
        expect(!fm.fileExists(atPath: linked.root.appendingPathComponent("tilr").path))
        expect(!fm.fileExists(atPath: linked.installationMarker.path))
        expect(fm.fileExists(atPath: base(linked).appendingPathComponent("running").path))
        // Reusing the same selection after removal must not offer or confirm removal again.
        expect(!linked.isInstalled)
        expect(linked.selection.binary == nil)
        let afterRemoval = commands(linked)
        expect(try linked.remove(confirmExternal: { fatalError("Removed pair must not ask") }) == .notInstalled)
        expect(commands(linked) == afterRemoval)
        // Discovery for uninstall with disabled integration never starts a service.
        let disabled = try fixture("disabled-removal")
        try executable(disabled.root.appendingPathComponent("tilrd"), "echo 'tilrd 1.0.0-abc (macos-aarch64)'\n")
        try disabled.locateForRemoval()
        expect(disabled.isInstalled && !commands(disabled).contains("service install"))
        // A marker for an unrelated executable cannot authorize removal.
        try Data(external.path.utf8).write(to: disabled.installationMarker)
        expect(!disabled.installedByApp)
        expect(try disabled.remove(confirmExternal: { false }) == .declined)
        // Resume a partial removal: daemon deletion succeeded but client/metadata remain.
        let partialRemoval = try fixture("partial-removal")
        _ = try partialRemoval.install()
        try fm.removeItem(at: partialRemoval.binary)
        expect(fm.fileExists(atPath: partialRemoval.root.appendingPathComponent("tilr").path))
        expect(try partialRemoval.remove() == .removed)
        expect(!fm.fileExists(atPath: partialRemoval.installationMarker.path))
        expect(!fm.fileExists(atPath: partialRemoval.root.appendingPathComponent("tilr").path))
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
        // An installed CLI can speak a newer protocol; only the bundled CLI validates app compatibility.
        let sibling = try fixture("incompatible-sibling")
        try executable(sibling.root.appendingPathComponent("tilr"), "echo 'tilrd 2.0.0-new at local'\n")
        try executable(sibling.source.appendingPathComponent("tilr"), "echo 'incompatible protocol' >&2\nexit 1\n")
        rejects { _ = try sibling.install() }
        rejects { _ = try sibling.credentials() }
        expect(!sibling.installedByApp)
        // A protocol/peer failure must not be treated as an absent server and overwritten.
        var incompatible = try fixture("incompatible")
        incompatible.runner = { _, _ in .init(status: 1, text: "incompatible protocol") }
        rejects { _ = try incompatible.install() }
        expect(!fm.fileExists(atPath: incompatible.root.path))
        // An authenticated protocol error is immediately actionable, without a startup wait.
        let incompatibleExecutable = base(incompatible).appendingPathComponent("external/tilrd")
        try executable(incompatibleExecutable, "echo 'tilrd 2.0.0-new (macos-aarch64)'\n")
        incompatible.runningExecutable = { incompatibleExecutable }
        rejects { _ = try incompatible.install() }
        expect(incompatible.binary == incompatibleExecutable)
        do {
            _ = try incompatible.waitReady(version: nil, startupTimeout: 1, retryInterval: 1,
                                           wait: { _ in fatalError("Protocol failures must not wait") })
            fatalError("Expected protocol failure")
        } catch {
            expect(error.localizedDescription.contains("incompatible protocol"))
            expect(error.localizedDescription.localizedCaseInsensitiveContains("update tilrd"))
        }
        // A reload can reset the handshake before the new daemon answers. Fake time
        // advances only on the controlled retry, with no real startup delay.
        var handoff = running
        let handoffRunner = running.runner!
        var probes = 0
        handoff.runner = { url, args in
            if args.last == "version" {
                probes += 1
                if probes == 1 { return .init(status: 1, text: "local.sock does not answer as tilrd does: Connection reset by peer") }
            }
            return try handoffRunner(url, args)
        }
        var handoffTime = Date(timeIntervalSince1970: 0)
        let afterHandoff = try handoff.waitReady(version: "2.0.0-new", startupTimeout: 2, retryInterval: 1,
                                               now: { handoffTime }, wait: { handoffTime.addTimeInterval($0) })
        expect(probes == 2 && afterHandoff["token"] == "shared-token")
        // Peer refusal is a security failure, never a transient startup condition.
        handoff.runner = { _, _ in .init(status: 1, text: "socket peer belongs to a different user") }
        rejects {
            _ = try handoff.waitReady(version: nil, startupTimeout: 2, retryInterval: 1,
                                     wait: { _ in fatalError("Peer failures must not wait") })
        }
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
