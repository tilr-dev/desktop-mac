import AppKit
import Gitpm

// The plugin manager in the app: `plugin_manager:` of the config → PluginManagerService
// (Sources/Gitpm, the Rust library gitpm, ../git/gitpm). No UI and no page bridge
// yet; Tilr Control `plugin-manager` reads the state, `--probe` checks the library on a
// temporary workspace.

extension Config.PluginManagerSettings {
    /// The service's settings: the workspace resolved against the config folder, no catalog when empty.
    var service: PluginManagerService.Settings {
        .init(root: Config.resolve(workspace), catalog: catalog.isEmpty ? nil : catalog)
    }
}

extension InstalledPackage {
    /// As Tilr Control returns it.
    var json: [String: Any] {
        var entry: [String: Any] = ["id": id, "source": source, "enabled": enabled,
                                    "version": version.map { $0 as Any } ?? NSNull(),
                                    "commit": current.map { $0.commit as Any } ?? NSNull()]
        if let previous { entry["previous"] = ["version": previous.version, "commit": previous.commit] }
        if let forkOf { entry["forkOf"] = ["id": forkOf.id, "version": forkOf.version, "commit": forkOf.commit] }
        return entry
    }
}

extension AppDelegate {
    /// Tilr Control `plugin-manager`: the workspace, the catalog, whether the workspace is open,
    /// git's availability and the installed plugins, read from state.json without opening
    /// (locking or creating) the workspace.
    func pluginManagerStatus() async throws -> [String: Any] {
        let (settings, open) = await pluginManager.status()
        let git = await Task.detached { PluginManagerService.gitProblem() }.value
        var result: [String: Any] = ["workspace": settings.root, "catalog": settings.catalog ?? NSNull(),
                                     "open": open, "git": git ?? "ok"]
        do {
            result["plugins"] = try await pluginManager.readInstalled(root: settings.root).map(\.json)
        } catch let failure as PluginManagerFailure {
            result["plugins"] = NSNull()
            result["error"] = ["kind": failure.kind, "message": failure.message]
        }
        return result
    }

    // MARK: Probe

    /// `--probe`, plugin manager: on a temporary workspace, never the configured one. Opens it
    /// (empty list), plans the uninstall of a missing plugin (repository_not_found), opens it a
    /// second time (locked), opens a fresh one from two services at once (one wins, the other
    /// is locked), reopens after close and after `configure`, and with git installs a local
    /// fixture repository, plans its uninstall (nothing lost) and uninstalls it.
    @MainActor
    func probePluginManager() async {
        let started = Date()
        func check(_ ok: Bool, _ message: @autoclosure () -> String) {
            guard !ok else { return }
            print("plugin manager: FAILED", message())
            Instance.terminating()
            exit(EXIT_FAILURE)
        }
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent("tilr-gitpm-probe-\(UUID().uuidString)")
        defer { try? files.removeItem(at: base) }
        let first = base.appendingPathComponent("workspace").path
        let second = base.appendingPathComponent("other").path
        let pm = PluginManagerService(settings: .init(root: first, catalog: nil), label: "dev.tilr.plugin-manager.probe")

        check(await Self.outcome { try await pm.open() } == "ok", "open of an empty workspace")
        let empty = try? await pm.list()
        check(empty?.isEmpty == true, "a new workspace did not return an empty list")
        let gitProblem = await Task.detached(operation: { PluginManagerService.gitProblem() }).value
        let missing = await Self.outcome { _ = try await pm.uninstallPlan(id: "probe/missing") }
        check(missing == (gitProblem == nil ? "repository_not_found" : "git"), "uninstall plan of a missing plugin: \(missing)")
        let other = PluginManagerService(settings: .init(root: first, catalog: nil), label: "dev.tilr.plugin-manager.probe2")
        let locked = await Self.outcome { try await other.open() }
        check(locked == "locked", "a second open of an open workspace: \(locked)")
        await pm.close()
        check(await Self.outcome { try await other.open() } == "ok", "open after the first service closed")
        await other.close()

        // Two services open one workspace at the same time: the lock lets exactly one in.
        let a = PluginManagerService(settings: .init(root: second, catalog: nil), label: "dev.tilr.plugin-manager.probe-a")
        let b = PluginManagerService(settings: .init(root: second, catalog: nil), label: "dev.tilr.plugin-manager.probe-b")
        async let ra = Self.outcome { try await a.open() }
        async let rb = Self.outcome { try await b.open() }
        let race = [await ra, await rb].sorted()
        check(race == ["locked", "ok"], "concurrent opens: \(race)")
        await a.close()
        await b.close()

        // configure: another workspace closes the open one; the next operation opens the new one.
        check(await Self.outcome { try await pm.open() } == "ok", "reopen")
        pm.configure(.init(root: second, catalog: nil))
        let root = try? await pm.root()
        check(root.map { URL(fileURLWithPath: $0).standardizedFileURL.path.hasSuffix("/other") } == true, "configure did not switch the workspace: \(root ?? "nil")")
        check(await Self.outcome { try await other.open() } == "ok", "configure did not release the first workspace")
        await other.close()

        var gitStep = "skipped"
        if let problem = gitProblem {
            gitStep = "skipped (\(problem))"
        } else {
            let source = base.appendingPathComponent("demo")
            do {
                try await Task.detached { try Self.makeProbePlugin(at: source) }.value
            } catch {
                check(false, "fixture repository: \(error.localizedDescription)")
            }
            let installed = try? await pm.install(source: source.path)
            check(installed?.id == "probe/demo" && installed?.current.version == "0.1.0", "install from a local repository: \(String(describing: installed))")
            let listed = (try? await pm.list()) ?? []
            check(listed.map(\.id) == ["probe/demo"] && listed.first?.enabled == true, "list after install: \(listed.map(\.id))")
            let plan = try? await pm.uninstallPlan(id: "probe/demo")
            check(plan?.registered == true && plan?.lostWork.isEmpty == true && plan?.dependents.isEmpty == true,
                  "uninstall plan of a clean install: \(String(describing: plan))")
            let replace = await Self.outcome { _ = try await pm.replace(original: "probe/other", replacement: "probe/demo") }
            check(replace == "invalid_argument", "replace by a plugin that declares no replaces: \(replace)")
            check(await Self.outcome { try await pm.uninstall(id: "probe/demo") } == "ok", "uninstall")
            check(((try? await pm.list()) ?? [listed.first!]).isEmpty, "list after uninstall")
            await probeReplacements(pm, base: base)
            gitStep = "install, plan, uninstall, replace, incompatible refusal, restore original: ok"
        }
        await pm.close()
        let took = Int(Date().timeIntervalSince(started) * 1000)
        print("plugin manager: open, empty list, missing plan → repository_not_found, second open → locked, concurrent opens → one locked, reopen, configure: ok; git fixture: \(gitStep) (\(took) ms)")
    }

    /// Exercise the real replacement API with local repositories and an installed consumer.
    @MainActor
    private func probeReplacements(_ pm: PluginManagerService, base: URL) async {
        do {
            for (name, dependencies, replaces) in [
                ("base", [:], nil),
                ("consumer", ["probe/base": "^1"], nil),
                ("replacement", [:], "1.0.0"),
                ("incompatible", [:], "2.0.0")
            ] as [(String, [String: String], String?)] {
                let source = base.appendingPathComponent(name)
                try await Task.detached {
                    try Self.makeProbePlugin(at: source, id: "probe/\(name)", version: "1.0.0",
                                             dependencies: dependencies, replaces: replaces)
                }.value
                _ = try await pm.install(source: source.path)
            }
            func provider(_ packages: [InstalledPackage]) -> String? {
                packages.first { $0.id == "probe/consumer" }?.dependencies.first { $0.id == "probe/base" && $0.satisfied }?.provider
            }
            guard provider(try await pm.list()) == "probe/base" else { throw ProbeReplacementFailure.state }
            let plan = try await pm.replace(original: "probe/base", replacement: "probe/replacement")
            guard plan.provider == "probe/replacement", plan.consumers == ["probe/consumer"],
                  provider(try await pm.list()) == "probe/replacement" else { throw ProbeReplacementFailure.state }
            _ = try await pm.replace(original: "probe/base", replacement: "probe/base")
            guard provider(try await pm.list()) == "probe/base" else { throw ProbeReplacementFailure.state }
            do {
                _ = try await pm.replace(original: "probe/base", replacement: "probe/incompatible")
                throw ProbeReplacementFailure.acceptedIncompatible
            } catch let failure as PluginManagerFailure {
                guard failure.kind == "incompatible_replacement", failure.plugins == ["probe/consumer"] else { throw failure }
            }
            guard provider(try await pm.list()) == "probe/base" else { throw ProbeReplacementFailure.state }
        } catch {
            print("plugin manager: FAILED replacement round trip:", error)
            Instance.terminating()
            exit(EXIT_FAILURE)
        }
    }

    private enum ProbeReplacementFailure: Error { case state, acceptedIncompatible }

    /// "ok", or the kind of the failure.
    nonisolated static func outcome(_ body: () async throws -> Void) async -> String {
        do { try await body(); return "ok" } catch { return PluginManagerFailure.from(error).kind }
    }

    /// A plugin repository like the library's scaffold: plugin.json, dist/, one commit, release
    /// tag `<id>@<version>`. The user's Git settings that would sign or ask are switched off.
    nonisolated static func makeProbePlugin(at directory: URL, id: String = "probe/demo", version: String = "0.1.0",
                                           dependencies: [String: String] = [:], replaces: String? = nil) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory.appendingPathComponent("dist"), withIntermediateDirectories: true)
        var manifest: [String: Any] = ["id": id, "version": version, "dependencies": dependencies]
        if let replaces { manifest["replaces"] = ["id": "probe/base", "version": replaces] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("plugin.json"))
        try "export const probe = true\n".write(to: directory.appendingPathComponent("dist/index.js"), atomically: true, encoding: .utf8)
        let config = ["-c", "user.name=Tilr probe", "-c", "user.email=probe@example.invalid",
                      "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        for arguments in [["init", "-q", "-b", "main"], ["add", "--all"], ["commit", "-q", "-m", "probe 0.1.0"], ["tag", "\(id)@\(version)"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            git.arguments = ["git", "-C", directory.path] + config + arguments
            git.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
            let errors = Pipe()
            git.standardOutput = FileHandle.nullDevice
            git.standardError = errors
            try git.run()
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            git.waitUntilExit()
            guard git.terminationStatus == 0 else {
                throw PluginManagerFailure(kind: "git", message: "git \(arguments.joined(separator: " ")): \(text)")
            }
        }
    }
}
