import Foundation
import CryptoKit
import Darwin

@main struct InstallationTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("tilr-install-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appendingPathComponent("bundle")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        var commands: [[String]] = []
        var loaded = false
        let runningState = "state = running\n\tpid = 4242"
        var jobState = runningState
        // Live panes the running server reports (`tilrd ps`); nil = it does not answer.
        var panes: Int? = 1
        // Whether launchd starts the job on bootstrap; false leaves it loaded with no process.
        var startsOnBootstrap = true
        var version = "1.0-build1-test"
        var signed = true
        var versionIdentity = "tilrd"
        var expectedReloadBytes: String?
        var reloadStatus: Int32 = 0
        var reloadThrows = false
        var runningVersion = "1.0-build1-test"
        var acceptsReload = true
        func expect(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
        func payload(_ build: Int, _ bytes: String) throws {
            version = "1.0-build\(build)-test"
            let data = Data(bytes.utf8)
            try data.write(to: source.appendingPathComponent("tilrd"))
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let manifest = ServerInstallation.Manifest(version: "1.0", build: build, arch: "arm64", serverVersion: version, sha256: sha, protocolVersion: 1, minAppBuild: 1, maxAppBuild: nil)
            try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("app-managed.json"))
        }
        let install = ServerInstallation(source: source, root: temp.appendingPathComponent("installed"),
            agents: temp.appendingPathComponent("agents"), label: "dev.tilr.test", port: 0, timeout: 5, origins: ["tilr://test"], appBuild: 20, protocolVersion: 1, architecture: "arm64",
            runner: { executable, args in
                commands.append([executable.lastPathComponent] + args)
                if executable.lastPathComponent == "codesign" { return .init(status: signed ? 0 : 1, text: "") }
                if executable.lastPathComponent == "launchctl" {
                    if args == ["kill", "SIGUSR1", "gui/\(getuid())/dev.tilr.test"] {
                        if let expectedReloadBytes {
                            let root = temp.appendingPathComponent("installed")
                            expect(try String(contentsOf: root.appendingPathComponent("tilrd"), encoding: .utf8) == expectedReloadBytes)
                            let receipt = try JSONDecoder().decode(ServerInstallation.Manifest.self, from: Data(contentsOf: root.appendingPathComponent("app-managed.json")))
                            expect(receipt.serverVersion == version)
                            expect(fm.fileExists(atPath: root.appendingPathComponent("pending-server.json").path))
                        }
                        if reloadThrows { throw ServerInstallation.Failure("launchctl could not run") }
                        if reloadStatus == 0 && acceptsReload { runningVersion = version }
                        return .init(status: reloadStatus, text: reloadStatus == 0 ? "" : "no such process")
                    }
                    if args[0] == "print" { return .init(status: loaded ? 0 : 1, text: loaded ? jobState : "") }
                    if args[0] == "bootstrap" { loaded = true; jobState = startsOnBootstrap ? runningState : "state = waiting" }
                    if args[0] == "kickstart" { jobState = runningState }
                    if args[0] == "bootout" { loaded = false }
                    return .init(status: 0, text: "")
                }
                if args == ["--version"] {
                    let meta = try JSONDecoder().decode(ServerInstallation.Manifest.self, from: Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("app-managed.json")))
                    return .init(status: 0, text: "\(versionIdentity) \(meta.serverVersion) (macos-aarch64)")
                }
                if args == ["state-formats"] {
                    fatalError("The app must delegate reload-state compatibility to tilrd")
                }
                if args == ["token"] { return .init(status: 0, text: "test-token") }
                if args == ["ps", "--url", "ws://127.0.0.1:0", "--server-version"] {
                    return .init(status: 0, text: runningVersion)
                }
                if args.first == "ps" {
                    guard let panes else { return .init(status: 1, text: "did not answer") }
                    let rows = (0..<panes).map { "pane-\($0)  100  80x24  0  ~  (shell)" }
                    return .init(status: 0, text: (["PANE  PID  SIZE  VIEWERS  CWD  COMMAND"] + rows).joined(separator: "\n"))
                }
                fatalError("unexpected command: \(args)")
            }, portCheck: {})
        func rejects(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected refusal") } catch { }
        }
        try payload(1, "one")
        for identity in ["tilr-server", "other"] {
            versionIdentity = identity
            rejects { _ = try install.install() }
            expect(!fm.fileExists(atPath: install.binary.path))
        }
        versionIdentity = "tilrd"
        _ = try install.install()
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "one")
        expect(commands.filter { $0.contains("bootstrap") }.count == 1)
        expect(!commands.contains { $0.contains("kill") })
        func plistJob() throws -> [String: Any] {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: install.plist), format: nil) as! [String: Any]
        }
        // Login Items attribute the job to the app (macOS 13+).
        expect(try plistJob()["AssociatedBundleIdentifiers"] as? [String] == [ServerInstallation.appBundleIdentifier])
        let inode = try fm.attributesOfItem(atPath: install.binary.path)[.systemFileNumber] as! NSNumber
        _ = try install.install()
        expect(try fm.attributesOfItem(atPath: install.binary.path)[.systemFileNumber] as! NSNumber == inode)
        commands.removeAll()
        try payload(2, "two")
        expectedReloadBytes = "two"
        _ = try install.install()
        expectedReloadBytes = nil
        expect(!commands.contains { $0.contains("state-formats") })
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        expect(try String(contentsOf: install.root.appendingPathComponent("tilrd.previous"), encoding: .utf8) == "one")
        expect(!commands.contains { $0.contains("bootout") || $0.contains("kickstart") })
        expect(commands.filter { $0.first == "launchctl" && $0[1] != "print" } == [["launchctl", "kill", "SIGUSR1", install.service]])
        commands.removeAll()
        _ = try install.install()
        expect(!commands.contains { $0.contains("kill") })
        try payload(1, "one")
        let retained = try install.install()
        expect(retained.build == 2)
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        let validReceipt = try Data(contentsOf: install.receipt)
        var incompatible = try JSONSerialization.jsonObject(with: validReceipt) as! [String: Any]
        for protocolVersion in [0, 2, 99] {
            incompatible["protocolVersion"] = protocolVersion
            try JSONSerialization.data(withJSONObject: incompatible).write(to: install.receipt)
            rejects { _ = try install.install() }
            expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        }
        try validReceipt.write(to: install.receipt)
        try payload(2, "altered same build")
        rejects { _ = try install.install() }
        try payload(3, "three")
        signed = false
        rejects { _ = try install.install() }
        signed = true
        _ = try install.install()
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "three")
        let originsChanged = ServerInstallation(source: source, root: install.root, agents: install.agents,
            label: install.label, port: 0, timeout: 5, origins: ["tilr://notes"], appBuild: 20, protocolVersion: 1, architecture: "arm64", runner: install.runner, portCheck: {})
        _ = try originsChanged.install()
        expect(commands.contains { $0 == ["launchctl", "kill", "SIGUSR1", install.service] })
        expect(try String(contentsOf: install.root.appendingPathComponent("origins.toml"), encoding: .utf8).contains("tilr://notes"))
        try Data("corrupted".utf8).write(to: source.appendingPathComponent("tilrd"))
        rejects { _ = try install.install() }
        try payload(4, "four")
        var conflict = install
        conflict.portCheck = { throw ServerInstallation.Failure("occupied") }
        loaded = false
        rejects { _ = try conflict.install() }
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "three")
        loaded = true
        let validPlist = try Data(contentsOf: install.plist)
        try Data("different service".utf8).write(to: install.plist)
        rejects { _ = try install.install() }
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "three")
        try validPlist.write(to: install.plist)
        // A separately downloaded update dies before rename, then the old bundle starts.
        try payload(5, "five")
        let incoming = try Data(contentsOf: source.appendingPathComponent("app-managed.json"))
        let pending = install.root.appendingPathComponent("pending-server.json")
        try incoming.write(to: pending)
        try payload(1, "one")
        expect(try install.install().build == 3)
        // The same interruption after rename must finalize the new receipt, not downgrade.
        try incoming.write(to: pending)
        try Data("five".utf8).write(to: install.binary)
        commands.removeAll()
        expect(try install.install().build == 5)
        expect(commands.filter { $0.first == "launchctl" && $0[1] != "print" } == [["launchctl", "kill", "SIGUSR1", install.service]])
        expect(!fm.fileExists(atPath: pending.path))
        // The job runs the binary itself. An earlier Tilr's job, the binary through `/bin/zsh -lc`,
        // is rewritten: left running when it runs (its terminals with it), replaced when stopped.
        func programArguments() throws -> [String] {
            let job = try PropertyListSerialization.propertyList(from: Data(contentsOf: install.plist), format: nil) as! [String: Any]
            return job["ProgramArguments"] as! [String]
        }
        expect(try programArguments() == [install.binary.path, "--listen", "127.0.0.1:0", "--config", install.root.appendingPathComponent("origins.toml").path])
        // Old-name installations require manual reinstall, even under our label.
        let currentPlist = try Data(contentsOf: install.plist)
        var oldJob = try PropertyListSerialization.propertyList(from: currentPlist, format: nil) as! [String: Any]
        oldJob["ProgramArguments"] = [install.root.appendingPathComponent("tilr-server").path]
        let oldPlist = try PropertyListSerialization.data(fromPropertyList: oldJob, format: .xml, options: 0)
        try oldPlist.write(to: install.plist)
        commands.removeAll()
        rejects { _ = try install.install() }
        expect(try Data(contentsOf: install.plist) == oldPlist)
        expect(!commands.contains { ["bootout", "bootstrap", "kickstart", "kill"].contains($0.dropFirst().first ?? "") })
        try currentPlist.write(to: install.plist)
        var wrapped = try PropertyListSerialization.propertyList(from: Data(contentsOf: install.plist), format: nil) as! [String: Any]
        wrapped["ProgramArguments"] = ["/bin/zsh", "-lc", "exec \"$1\" --listen \"$2\" --config \"$3\"", "tilrd",
                                       install.binary.path, "127.0.0.1:0", install.root.appendingPathComponent("origins.toml").path]
        let wrappedPlist = try PropertyListSerialization.data(fromPropertyList: wrapped, format: .xml, options: 0)
        try wrappedPlist.write(to: install.plist)
        commands.removeAll()
        _ = try install.install()
        expect(try programArguments().first == install.binary.path)
        expect(!commands.contains { ["bootout", "bootstrap", "kickstart", "kill"].contains($0.dropFirst().first ?? "") })
        try wrappedPlist.write(to: install.plist)
        jobState = "state = not running"
        commands.removeAll()
        _ = try install.install()
        expect(try programArguments().first == install.binary.path)
        let launchd = commands.filter { $0.first == "launchctl" && $0[1] != "print" }.map { $0[1] }
        expect(launchd == ["bootout", "bootstrap"])
        expect(loaded && jobState == runningState)
        // A direct job written before the app association (key missing or another value) is
        // rewritten the same way: running left alone, stopped replaced.
        for associated in [nil, ["dev.tilr.old"]] as [[String]?] {
            var unassociated = try plistJob()
            unassociated["AssociatedBundleIdentifiers"] = associated
            let unassociatedPlist = try PropertyListSerialization.data(fromPropertyList: unassociated, format: .xml, options: 0)
            try unassociatedPlist.write(to: install.plist)
            jobState = runningState
            commands.removeAll()
            _ = try install.install()
            expect(try plistJob()["AssociatedBundleIdentifiers"] as? [String] == [ServerInstallation.appBundleIdentifier])
            expect(!commands.contains { ["bootout", "bootstrap", "kickstart", "kill"].contains($0.dropFirst().first ?? "") })
            try unassociatedPlist.write(to: install.plist)
            jobState = "state = not running"
            commands.removeAll()
            _ = try install.install()
            expect(try plistJob()["AssociatedBundleIdentifiers"] as? [String] == [ServerInstallation.appBundleIdentifier])
            expect(commands.filter { $0.first == "launchctl" && $0[1] != "print" }.map { $0[1] } == ["bootout", "bootstrap"])
        }
        // A zsh-wrapped job from before the association migrates too.
        var wrappedOld = wrapped
        wrappedOld.removeValue(forKey: "AssociatedBundleIdentifiers")
        try PropertyListSerialization.data(fromPropertyList: wrappedOld, format: .xml, options: 0).write(to: install.plist)
        _ = try install.install()
        expect(try programArguments().first == install.binary.path)
        expect(try plistJob()["AssociatedBundleIdentifiers"] as? [String] == [ServerInstallation.appBundleIdentifier])
        // Our job with another definition (here an extra environment variable) is applied:
        // a running server with live panes keeps the old definition, the file is rewritten and a
        // restart is pending; with no panes it is booted out and bootstrapped at once.
        func launchdCalls() -> [String] { commands.filter { $0.first == "launchctl" && $0[1] != "print" }.map { $0[1] } }
        func environment() throws -> [String: String] { try plistJob()["EnvironmentVariables"] as! [String: String] }
        var otherEnv = try plistJob()
        var env = otherEnv["EnvironmentVariables"] as! [String: String]
        env["TILR_EXTRA"] = "1"
        otherEnv["EnvironmentVariables"] = env
        let otherEnvPlist = try PropertyListSerialization.data(fromPropertyList: otherEnv, format: .xml, options: 0)
        let before = try Data(contentsOf: install.plist)
        try? fm.removeItem(at: install.restartMarker)
        for answer in [2, nil] as [Int?] {
            try otherEnvPlist.write(to: install.plist)
            loaded = true; jobState = runningState; panes = answer
            commands.removeAll()
            _ = try install.install()
            expect(try environment()["TILR_EXTRA"] == nil)
            expect(launchdCalls().isEmpty)
            expect(install.restartPending())
        }
        // The panes closed: the next install (the next launch) applies the pending definition.
        panes = 0
        commands.removeAll()
        _ = try install.install()
        expect(launchdCalls() == ["bootout", "bootstrap"])
        expect(!install.restartPending() && loaded)
        commands.removeAll()
        _ = try install.install()
        expect(launchdCalls().isEmpty)
        // No panes from the start: applied at once.
        try otherEnvPlist.write(to: install.plist)
        commands.removeAll()
        _ = try install.install()
        expect(launchdCalls() == ["bootout", "bootstrap"])
        expect(try environment()["TILR_EXTRA"] == nil && !install.restartPending())
        // Bootstrapped but held back (loaded, no pid): kickstarted.
        try otherEnvPlist.write(to: install.plist)
        startsOnBootstrap = false
        commands.removeAll()
        _ = try install.install()
        expect(launchdCalls() == ["bootout", "bootstrap", "kickstart"])
        expect(jobState == runningState)
        startsOnBootstrap = true
        // The dialog's Restart Server…: bootout and bootstrap whatever the panes.
        panes = 3
        commands.removeAll()
        try install.restart()
        expect(launchdCalls() == ["bootout", "bootstrap"])
        panes = 1
        // Pending is read from launchd: its loaded program/arguments/environment against the file.
        // A login that loaded the new file clears a stale marker; a mismatch is pending without one.
        let file = try plistJob()
        let fileArgs = file["ProgramArguments"] as! [String]
        func printed(_ args: [String], _ env: [String: String]) -> String {
            (["gui/501/\(install.label) = {", "\tstate = running", "", "\tprogram = \(args[0])", "\targuments = {"]
             + args.map { "\t\t" + $0 } + ["\t}", "", "\tinherited environment = {", "\t\tSSH_AUTH_SOCK => /x", "\t}",
             "\tdefault environment = {", "\t\tPATH => /usr/bin", "\t}", "", "\tenvironment = {"]
             + (env.merging(["OSLogRateLimit": "64", "XPC_SERVICE_NAME": install.label]) { a, _ in a })
                .sorted { $0.key < $1.key }.map { "\t\t\($0.key) => \($0.value)" }
             + ["\t}", "", "\tpid = 4242", "}"]).joined(separator: "\n")
        }
        let fileEnv = file["EnvironmentVariables"] as! [String: String]
        try Data().write(to: install.restartMarker)
        expect(ServerInstallation.loadedDefinition(printed(fileArgs, fileEnv), matches: file) == true)
        loaded = true; jobState = printed(fileArgs, fileEnv)
        expect(!install.restartPending() && !fm.fileExists(atPath: install.restartMarker.path))
        jobState = printed(fileArgs, fileEnv.merging(["TILR_EXTRA": "1"]) { a, _ in a })
        expect(install.restartPending())
        jobState = printed(fileArgs.dropLast(2) + ["--config", "/elsewhere"], fileEnv)
        expect(install.restartPending())
        // Unparseable output: the marker decides.
        jobState = runningState
        expect(!install.restartPending())
        try Data().write(to: install.restartMarker)
        expect(install.restartPending())
        // Not loaded: the next bootstrap reads the file; nothing pending, marker cleared.
        loaded = false
        expect(!install.restartPending() && !fm.fileExists(atPath: install.restartMarker.path))
        loaded = true; jobState = runningState
        // Another binary or another program is refused.
        var otherBinary = try PropertyListSerialization.propertyList(from: before, format: nil) as! [String: Any]
        otherBinary["ProgramArguments"] = ["/usr/local/bin/other-server", "--listen", "127.0.0.1:0"]
        try PropertyListSerialization.data(fromPropertyList: otherBinary, format: .xml, options: 0).write(to: install.plist)
        rejects { _ = try install.install() }
        try before.write(to: install.plist)
        var foreign = wrapped
        foreign["ProgramArguments"] = ["/bin/zsh", "-lc", "exec /usr/local/bin/other-server"]
        let valid = try Data(contentsOf: install.plist)
        try PropertyListSerialization.data(fromPropertyList: foreign, format: .xml, options: 0).write(to: install.plist)
        rejects { _ = try install.install() }
        var renamed = wrapped
        renamed["Label"] = "dev.other.server"
        try PropertyListSerialization.data(fromPropertyList: renamed, format: .xml, options: 0).write(to: install.plist)
        rejects { _ = try install.install() }
        try valid.write(to: install.plist)
        expect(try install.install().build == 5)
        // Removal. A foreign plist is left alone, launchd untouched.
        try PropertyListSerialization.data(fromPropertyList: renamed, format: .xml, options: 0).write(to: install.plist)
        commands.removeAll()
        rejects { _ = try install.remove() }
        expect(launchdCalls().isEmpty && fm.fileExists(atPath: install.binary.path))
        try valid.write(to: install.plist)
        // Ours: booted out, plist and installed files gone, state kept.
        try fm.createDirectory(at: install.state, withIntermediateDirectories: true)
        try Data("session".utf8).write(to: install.state.appendingPathComponent("sessions.json"))
        try fm.createDirectory(at: install.root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try Data().write(to: install.restartMarker)
        loaded = true; jobState = runningState
        commands.removeAll()
        expect(try install.remove() == .removed)
        expect(launchdCalls() == ["bootout"] && !loaded)
        for gone in [install.plist, install.binary, install.receipt, install.restartMarker,
                     install.root.appendingPathComponent("origins.toml"), install.root.appendingPathComponent("runtime"),
                     install.root.appendingPathComponent("tilrd.previous"), install.root.appendingPathComponent("app-managed.previous.json")] {
            expect(!fm.fileExists(atPath: gone.path))
        }
        expect(fm.fileExists(atPath: install.state.appendingPathComponent("sessions.json").path))
        expect(!install.isInstalled)
        // Not installed: nothing to do.
        commands.removeAll()
        expect(try install.remove() == .notInstalled)
        expect(launchdCalls().isEmpty)
        // A loaded job of our name without our file is not ours to remove.
        loaded = true
        rejects { _ = try install.remove() }
        loaded = false
        // The next install is a fresh one from the bundle.
        try payload(6, "six")
        commands.removeAll()
        expect(try install.install().build == 6)
        expect(launchdCalls() == ["bootstrap"])
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "six" && install.isInstalled)
        // Failure to request reload keeps the installed release, its receipt and manual recovery.
        // Both a nonzero launchctl result and failure to launch it reach the explicit update error.
        for build in [7, 8] {
            let previousBytes = try Data(contentsOf: install.binary)
            let previousReceipt = try Data(contentsOf: install.receipt)
            try payload(build, "release-\(build)")
            expectedReloadBytes = "release-\(build)"
            reloadStatus = build == 7 ? 1 : 0
            reloadThrows = build == 8
            commands.removeAll()
            do {
                _ = try install.install()
                fatalError("Expected reload request failure")
            } catch {
                expect(error.localizedDescription.contains("update was installed"))
                expect(error.localizedDescription.contains("server was not reloaded"))
                expect(error.localizedDescription.contains(build == 7 ? "no such process" : "launchctl could not run"))
            }
            expect(launchdCalls() == ["kill"])
            expect(try String(contentsOf: install.binary, encoding: .utf8) == "release-\(build)")
            expect(try Data(contentsOf: install.receipt) == Data(contentsOf: source.appendingPathComponent("app-managed.json")))
            expect(try Data(contentsOf: install.root.appendingPathComponent("tilrd.previous")) == previousBytes)
            expect(try Data(contentsOf: install.root.appendingPathComponent("app-managed.previous.json")) == previousReceipt)
            expect(fm.fileExists(atPath: pending.path))
            reloadStatus = 0
            reloadThrows = false
            commands.removeAll()
            expect(try install.install().build == build)
            expect(launchdCalls() == ["kill"])
            expect(!fm.fileExists(atPath: pending.path))
        }
        expectedReloadBytes = nil
        reloadStatus = 0
        reloadThrows = false
        // A stopped or unloaded job starts the new binary directly, without a reload signal.
        for build in [9, 10] {
            try payload(build, "release-\(build)")
            loaded = build == 9
            jobState = "state = waiting"
            commands.removeAll()
            expect(try install.install().build == build)
            expect(launchdCalls() == (build == 9 ? ["kickstart"] : ["bootstrap"]))
        }
        // Binary and origins changes share one request after both files have been installed.
        try payload(11, "eleven")
        expectedReloadBytes = "eleven"
        commands.removeAll()
        _ = try originsChanged.install()
        expect(launchdCalls() == ["kill"])
        expect(try String(contentsOf: install.root.appendingPathComponent("origins.toml"), encoding: .utf8).contains("tilr://notes"))
        expectedReloadBytes = nil
        // The daemon owns format compatibility: successful signal delivery can still leave
        // the old supervisor serving its terminals. Readiness must observe the live version.
        try payload(12, "twelve")
        acceptsReload = false
        let oldVersion = runningVersion
        commands.removeAll()
        let refused = try install.install()
        expect(refused.build == 12)
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "twelve")
        var clock = Date(timeIntervalSince1970: 0)
        var waits = 0
        func waitForReadiness(_ expected: String) throws -> [String: String] {
            try install.waitReady(version: expected, startupTimeout: 2, retryInterval: 1,
                                  now: { clock }, wait: { interval in
                                      waits += 1
                                      clock = clock.addingTimeInterval(interval)
                                  })
        }
        do {
            _ = try waitForReadiness(refused.serverVersion)
            fatalError("An old supervisor must not complete the update")
        } catch {
            expect(error.localizedDescription.contains("Reload did not complete"))
            expect(error.localizedDescription.contains("running version \(oldVersion)"))
            expect(error.localizedDescription.contains("expected \(refused.serverVersion)"))
            expect(error.localizedDescription.contains("Existing processes were not stopped"))
        }
        expect(waits == 2 && loaded && jobState == runningState && panes == 1)
        expect(launchdCalls() == ["kill"])
        expect(commands.filter { $0 == ["tilrd", "ps", "--url", install.endpoint, "--server-version"] }.count == 2)
        expect(!commands.contains { $0.contains("state-formats") })
        // The next update is accepted: readiness returns credentials only for the new version.
        try payload(13, "thirteen")
        acceptsReload = true
        commands.removeAll()
        let accepted = try install.install()
        waits = 0
        expect(try waitForReadiness(accepted.serverVersion)["token"] == "test-token")
        expect(waits == 0 && runningVersion == accepted.serverVersion)
        expect(loaded && jobState == runningState && panes == 1)
        expect(launchdCalls() == ["kill"])
        expect(commands.contains { $0 == ["tilrd", "ps", "--url", install.endpoint, "--server-version"] })
        expect(!commands.contains { $0.contains("state-formats") })
        print("server installation: first install, idempotence, live upgrade, downgrade prevention, signatures, daemon-owned format compatibility, crash recovery, checksum, service/port conflicts, zsh-wrapped and unassociated job migration, app association, changed definition applied without panes / pending with panes, kickstart of a held-back job, pending read from launchd (match clears a stale marker, mismatch pending, marker fallback), restart, removal (ours / foreign / not installed) and reinstall: passed")
        if let payload = CommandLine.arguments.dropFirst().first {
            var real = ServerInstallation(source: URL(fileURLWithPath: payload),
                root: temp.appendingPathComponent("real"), agents: temp.appendingPathComponent("real-agents"),
                label: "dev.tilr.test-real", port: 0, timeout: 15, origins: ["tilr://test"], appBuild: 20, protocolVersion: 1, architecture: "arm64")
            let processes = real
            real.runner = { executable, args in
                if executable.lastPathComponent == "launchctl" {
                    return .init(status: args[0] == "print" ? 1 : 0, text: "")
                }
                return try processes.command(executable, args)
            }
            real.portCheck = {}
            _ = try real.install()
            expect(try real.hash(real.binary) == real.hash(real.source.appendingPathComponent("tilrd")))
            let credentials = try real.credentials()
            expect(credentials["token"]?.count == 64)
            let update = try real.command(real.binary, ["update", "--cdn", "http://127.0.0.1:1"])
            expect(update.status != 0 && update.text.contains("managed by Tilr.app"))
            print("real payload: signature, version, installed binary, private token and updater ownership: passed (launchd simulated)")
        }
    }
}
