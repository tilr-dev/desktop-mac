import Foundation

@main struct UninstallTests {
    static func main() async throws {
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
                precondition(removal == .removed)
            }
            var questions = 0
            var stopped = false
            var preferencesCleaned = false
            var trashed = false
            let uninstall = AppUninstall(bundle: app, dataDirectories: [data], trash: { url in
                precondition(stopped && preferencesCleaned && !fm.fileExists(atPath: data.path))
                if scenario == "trash-error" { throw Failure.expected }
                try fm.moveItem(at: url, to: base.appendingPathComponent("Trash.app"))
                trashed = true
            })
            do {
                try await uninstall.run(removeServer: {
                    _ = try installation.remove(confirmExternal: { questions += 1; return scenario == "external-yes" })
                }, stop: { stopped = true }, cleanPreferences: { preferencesCleaned = true })
                precondition(scenario != "service-error" && scenario != "trash-error")
            } catch {
                precondition(scenario == "service-error" || scenario == "trash-error")
            }
            precondition(questions == (owned ? 0 : 1))
            let token = try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8)
            precondition(token == "original")
            if scenario == "service-error" {
                precondition(!stopped && !preferencesCleaned && !trashed)
                precondition(fm.fileExists(atPath: data.path) && fm.fileExists(atPath: server.path))
            } else {
                precondition(stopped && preferencesCleaned && !fm.fileExists(atPath: data.path))
                precondition(trashed == (scenario != "trash-error"))
                precondition(fm.fileExists(atPath: server.path) == (scenario == "external-no"))
                precondition(fm.fileExists(atPath: client.path) == !owned)
            }
            precondition(commands.isEmpty == (scenario == "external-no"))
            if scenario == "owned-removed" { precondition(commands.count == 1) }
            precondition(fm.fileExists(atPath: app.path) == !trashed)
        }
        print("application uninstall tests passed")
    }
}
