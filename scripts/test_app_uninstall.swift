import Foundation

@main struct UninstallTests {
    static func main() async {
        do { try await run() } catch { fail("Unexpected error: \(error)") }
    }

    @MainActor static func run() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("tilr-uninstall-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        enum Failure: Error { case expected }

        for scenario in ["owned", "owned-removed", "external-no", "external-yes", "service-error", "trash-error"] {
            let base = temp.appendingPathComponent(scenario)
            let bin = base.appendingPathComponent("bin")
            let app = base.appendingPathComponent("Tilr.app")
            let data = base.appendingPathComponent("app-data")
            let state = base.appendingPathComponent("shared-state")
            for directory in [bin, app, data, state] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            let server = bin.appendingPathComponent("tilrd")
            let client = bin.appendingPathComponent("tilr")
            for file in [server, client, state.appendingPathComponent("token")] { try Data("original".utf8).write(to: file) }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
            let owned = scenario != "external-no" && scenario != "external-yes"
            var installation = ServerInstallation(source: bin, root: bin, agents: base, label: "fixture", port: 7890,
                timeout: 1, origins: [], protocolVersion: 1, architecture: "arm64")
            if owned { try Data(server.path.utf8).write(to: installation.installationMarker) }
            var commands: [[String]] = []
            installation.runner = { _, args in
                commands.append(args)
                return .init(status: scenario == "service-error" ? 1 : 0, text: "fixture")
            }
            if scenario == "owned-removed" {
                installation.selection.found = true
                installation.selection.binary = server
                let removal = try installation.remove()
                expect(removal == .removed)
            }
            var questions = 0
            var stopped = false
            var preferencesCleaned = false
            var trashed = false
            let uninstall = AppUninstall(bundle: app, dataDirectories: [data], trash: { url in
                expect(stopped && preferencesCleaned && !fm.fileExists(atPath: data.path))
                if scenario == "trash-error" { throw Failure.expected }
                try fm.moveItem(at: url, to: base.appendingPathComponent("Trash.app"))
                trashed = true
            })
            do {
                try await uninstall.run(removeServer: {
                    _ = try installation.remove(confirmExternal: { questions += 1; return scenario == "external-yes" })
                }, stop: { stopped = true }, cleanPreferences: { preferencesCleaned = true })
                expect(scenario != "service-error" && scenario != "trash-error")
            } catch {
                expect(scenario == "service-error" || scenario == "trash-error")
            }
            expect(questions == (owned ? 0 : 1))
            let token = try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8)
            expect(token == "original")
            if scenario == "service-error" {
                expect(!stopped && !preferencesCleaned && !trashed)
                expect(fm.fileExists(atPath: data.path) && fm.fileExists(atPath: server.path))
            } else {
                expect(stopped && preferencesCleaned && !fm.fileExists(atPath: data.path))
                expect(trashed == (scenario != "trash-error"))
                expect(fm.fileExists(atPath: server.path) == (scenario == "external-no"))
                expect(fm.fileExists(atPath: client.path) == !owned)
            }
            expect(commands.isEmpty == (scenario == "external-no"))
            if scenario == "owned-removed" { expect(commands.count == 1) }
            expect(fm.fileExists(atPath: app.path) == !trashed)
        }
        print("application uninstall tests passed")
    }
}
