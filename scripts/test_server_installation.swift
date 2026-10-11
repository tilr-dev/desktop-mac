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
        var jobState = "state = running"
        var formats = "supervisor-state 1\npane-state 1"
        let installedFormats = formats
        var version = "1.0-build1-test"
        var signed = true
        func expect(_ value: Bool) { precondition(value) }
        func payload(_ build: Int, _ bytes: String) throws {
            version = "1.0-build\(build)-test"
            let data = Data(bytes.utf8)
            try data.write(to: source.appendingPathComponent("tilr-server"))
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let manifest = ServerInstallation.Manifest(version: "1.0", build: build, arch: "arm64", serverVersion: version, sha256: sha, protocolVersion: 2, minAppBuild: 1, maxAppBuild: nil)
            try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("app-managed.json"))
        }
        let install = ServerInstallation(source: source, root: temp.appendingPathComponent("installed"),
            agents: temp.appendingPathComponent("agents"), label: "dev.tilr.test", port: 0, timeout: 5, origins: ["tilr://test"], appBuild: 20, protocolVersion: 2, architecture: "arm64",
            runner: { executable, args in
                commands.append([executable.lastPathComponent] + args)
                if executable.lastPathComponent == "codesign" { return .init(status: signed ? 0 : 1, text: "") }
                if executable.lastPathComponent == "launchctl" {
                    if args[0] == "print" { return .init(status: loaded ? 0 : 1, text: loaded ? jobState : "") }
                    if args[0] == "bootstrap" { loaded = true; jobState = "state = running" }
                    if args[0] == "bootout" { loaded = false }
                    return .init(status: 0, text: "")
                }
                if args == ["--version"] {
                    let meta = try JSONDecoder().decode(ServerInstallation.Manifest.self, from: Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("app-managed.json")))
                    return .init(status: 0, text: "tilr-server \(meta.serverVersion) (macos-aarch64)")
                }
                if args == ["state-formats"] {
                    return .init(status: 0, text: executable.deletingLastPathComponent().path == source.path ? formats : installedFormats)
                }
                if args == ["token"] { return .init(status: 0, text: "test-token") }
                fatalError("unexpected command: \(args)")
            }, portCheck: {})
        func rejects(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected refusal") } catch { }
        }
        try payload(1, "one")
        _ = try install.install()
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "one")
        expect(commands.filter { $0.contains("bootstrap") }.count == 1)
        let inode = try fm.attributesOfItem(atPath: install.binary.path)[.systemFileNumber] as! NSNumber
        _ = try install.install()
        expect(try fm.attributesOfItem(atPath: install.binary.path)[.systemFileNumber] as! NSNumber == inode)
        try payload(2, "two")
        _ = try install.install()
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        expect(try String(contentsOf: install.root.appendingPathComponent("tilr-server.previous"), encoding: .utf8) == "one")
        expect(!commands.contains { $0.contains("bootout") || $0.contains("kickstart") })
        try payload(1, "one")
        let retained = try install.install()
        expect(retained.build == 2)
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        let validReceipt = try Data(contentsOf: install.receipt)
        var incompatible = try JSONSerialization.jsonObject(with: validReceipt) as! [String: Any]
        incompatible["protocolVersion"] = 99
        try JSONSerialization.data(withJSONObject: incompatible).write(to: install.receipt)
        rejects { _ = try install.install() }
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        try validReceipt.write(to: install.receipt)
        try payload(2, "altered same build")
        rejects { _ = try install.install() }
        try payload(3, "three")
        signed = false
        rejects { _ = try install.install() }
        signed = true
        formats = "supervisor-state 2\npane-state 1"
        rejects { _ = try install.install() }
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "two")
        formats = installedFormats
        try Data(contentsOf: source.appendingPathComponent("app-managed.json")).write(to: install.receipt)
        _ = try install.install()
        expect(try String(contentsOf: install.binary, encoding: .utf8) == "three")
        let originsChanged = ServerInstallation(source: source, root: install.root, agents: install.agents,
            label: install.label, port: 0, timeout: 5, origins: ["tilr://notes"], appBuild: 20, protocolVersion: 2, architecture: "arm64", runner: install.runner, portCheck: {})
        _ = try originsChanged.install()
        expect(commands.contains { $0 == ["launchctl", "kill", "SIGUSR1", install.service] })
        expect(try String(contentsOf: install.root.appendingPathComponent("origins.toml"), encoding: .utf8).contains("tilr://notes"))
        try Data("corrupted".utf8).write(to: source.appendingPathComponent("tilr-server"))
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
        expect(try install.install().build == 5)
        expect(!fm.fileExists(atPath: pending.path))
        // The job runs the binary itself. An earlier Tilr's job, the binary through `/bin/zsh -lc`,
        // is rewritten: left running when it runs (its terminals with it), replaced when stopped.
        func programArguments() throws -> [String] {
            let job = try PropertyListSerialization.propertyList(from: Data(contentsOf: install.plist), format: nil) as! [String: Any]
            return job["ProgramArguments"] as! [String]
        }
        expect(try programArguments() == [install.binary.path, "--listen", "127.0.0.1:0", "--config", install.root.appendingPathComponent("origins.toml").path])
        var wrapped = try PropertyListSerialization.propertyList(from: Data(contentsOf: install.plist), format: nil) as! [String: Any]
        wrapped["ProgramArguments"] = ["/bin/zsh", "-lc", "exec \"$1\" --listen \"$2\" --config \"$3\"", "tilr-server",
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
        expect(loaded && jobState == "state = running")
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
        print("server installation: first install, idempotence, live upgrade, downgrade prevention, signatures, format compatibility, crash recovery, checksum, service/port conflicts, zsh-wrapped job migration: passed")
        if let payload = CommandLine.arguments.dropFirst().first {
            var real = ServerInstallation(source: URL(fileURLWithPath: payload),
                root: temp.appendingPathComponent("real"), agents: temp.appendingPathComponent("real-agents"),
                label: "dev.tilr.test-real", port: 0, timeout: 15, origins: ["tilr://test"], appBuild: 20, protocolVersion: 2, architecture: "arm64")
            let processes = real
            real.runner = { executable, args in
                if executable.lastPathComponent == "launchctl" {
                    return .init(status: args[0] == "print" ? 1 : 0, text: "")
                }
                return try processes.command(executable, args)
            }
            real.portCheck = {}
            _ = try real.install()
            expect(try real.hash(real.binary) == real.hash(real.source.appendingPathComponent("tilr-server")))
            let credentials = try real.credentials()
            expect(credentials["token"]?.count == 64)
            let update = try real.command(real.binary, ["update", "--cdn", "http://127.0.0.1:1"])
            expect(update.status != 0 && update.text.contains("managed by Tilr.app"))
            print("real payload: signature, version, installed binary, private token and updater ownership: passed (launchd simulated)")
        }
    }
}
