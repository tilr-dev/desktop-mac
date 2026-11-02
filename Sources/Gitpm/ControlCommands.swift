import Foundation
import CoreFoundation

private func invalid(_ message: String) -> PluginManagerFailure {
    .init(kind: "invalid_argument", message: "gitpm: \(message)")
}

/// A strict object schema: typos and workspace overrides fail before opening the manager.
private struct CommandArguments {
    let values: [String: Any]
    init(_ values: [String: Any], allowed: String) throws {
        let keys = Set(allowed.split(separator: " ").map(String.init))
        guard Set(values.keys).isSubset(of: keys) else {
            throw invalid("unexpected arguments: \(Set(values.keys).subtracting(keys).sorted().joined(separator: ", "))")
        }
        self.values = values
    }
    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String, !value.isEmpty else { throw invalid("\(key) must be a nonempty string") }
        return value
    }
    func optional(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw invalid("\(key) must be a string or null") }
        return text
    }
    func flag(_ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw invalid("\(key) must be a boolean")
        }
        return number.boolValue
    }
    func strings(_ key: String) throws -> [String] {
        guard let value = values[key] as? [String] else { throw invalid("\(key) must be an array of strings") }
        return value
    }
    func object(_ key: String) throws -> [String: Any] {
        guard let value = values[key] as? [String: Any] else { throw invalid("\(key) must be an object") }
        return value
    }
    func installTarget() throws -> InstallTarget {
        switch try optional("target") ?? "release" {
        case "release": return .release
        case "dev": return .dev
        case "ref": return .ref(reference: try string("reference"))
        default: throw invalid("target must be release, dev or ref")
        }
    }
    func target() throws -> Target {
        if try optional("target") == "recorded" { return .recorded }
        switch try installTarget() {
        case .release: return .release
        case .dev: return .dev
        case .ref(let reference): return .ref(reference: reference)
        }
    }
    func dependencyEdit() throws -> DependencyEdit {
        let edit = try CommandArguments(object("edit"), allowed: "type dependency newDependency requirement")
        switch try edit.string("type") {
        case "add": return .add(dependency: try edit.string("dependency"), requirement: try edit.string("requirement"))
        case "update": return .update(dependency: try edit.string("dependency"), newDependency: try edit.string("newDependency"), requirement: try edit.string("requirement"))
        case "remove": return .remove(dependency: try edit.string("dependency"))
        default: throw invalid("edit.type must be add, update or remove")
        }
    }
}

extension LostWork {
    fileprivate static func argument(_ value: [String: Any]) throws -> LostWork {
        let args = try CommandArguments(value, allowed: "type path head recorded commit summary name commits entry")
        switch try args.string("type") {
        case "modified": return .modified(path: try args.string("path"))
        case "untracked": return .untracked(path: try args.string("path"))
        case "ignored": return .ignored(path: try args.string("path"))
        case "headMoved": return .headMoved(head: try args.string("head"), recorded: try args.string("recorded"))
        case "unpublishedCommit": return .unpublishedCommit(commit: try args.string("commit"), summary: try args.string("summary"))
        case "unpublishedBranch":
            guard let number = value["commits"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let commits = UInt64(number.stringValue) else { throw invalid("commits must be an unsigned integer") }
            return .unpublishedBranch(name: try args.string("name"), commits: commits)
        case "unpublishedTag": return .unpublishedTag(name: try args.string("name"))
        case "stash": return .stash(entry: try args.string("entry"))
        default: throw invalid("unknown lost-work type")
        }
    }
}

extension PluginManagerService {
    /// All Control commands, including free FFI functions, share the manager's serial queue.
    /// Arguments are converted before queueing; only the queue may read settings/open a manager.
    public func execute(command: String, arguments: [String: Any]) async throws -> Any {
        let body: (PluginManagerService) throws -> Any
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        func args(_ allowed: String = "") throws -> CommandArguments { try .init(arguments, allowed: allowed) }
        // Preflight only commands that actually invoke Git. Do not run Apple's Git stub.
        let gitCommands: Set<String> = ["install", "installFromCatalog", "download", "downloadFromCatalog", "check", "update", "updateAll", "updateAllPlan", "rollback", "restore", "uninstall", "uninstallPlan", "uninstallRefusal", "fork", "forkPackages", "forkSource", "authCheck", "init", "commit", "setRemote", "catalogUpdate", "catalogRegister", "repositoryPackages", "editRepositoryDependency", "link", "replaceResolve"]
        switch command {
        case "open":
            _ = try args(); body = { _ = try $0.openManager(); return NSNull() }
        case "root":
            _ = try args(); body = { $0.settings.root }
        case "list":
            _ = try args(); body = { try json($0.openManager().list()) }
        case "readState":
            _ = try args(); body = { try json(Gitpm.readState(root: $0.settings.root)) }
        case "listView":
            let a = try args("provides"), provides = try a.optional("provides")
            body = { try json(Gitpm.list(root: $0.settings.root, provides: provides)) }
        case "check":
            _ = try args(); body = { try json(Gitpm.check(root: $0.settings.root, catalog: $0.settings.catalog, customSsh: false)) }
        case "browseCatalog", "catalogLinks", "catalogRelease":
            let a = try args(command == "catalogRelease" ? "location id version" : "location")
            let location = try a.optional("location")
            let id = command == "catalogRelease" ? try a.string("id") : ""
            let version = try a.optional("version")
            body = { service in
                guard let location = location ?? service.settings.catalog else { throw invalid("no catalog configured; supply location") }
                switch command {
                case "browseCatalog": return try json(Gitpm.browseCatalog(location: location))
                case "catalogLinks": return try json(Gitpm.catalogLinks(location: location))
                default: return try json(Gitpm.catalogRelease(location: location, id: id, version: version))
                }
            }
        case "install", "download":
            let a = try args(command == "install" ? "source target reference package force" : "source target reference package")
            let source = try a.string("source"), target = try a.installTarget(), package = try a.optional("package"), force = try a.flag("force")
            body = { service in
                let manager = try service.openManager()
                return try json(command == "install" ? manager.install(source: source, target: target, package: package, force: force) : manager.download(source: source, target: target, package: package))
            }
        case "installFromCatalog", "downloadFromCatalog":
            let a = try args(command == "installFromCatalog" ? "id version force" : "id version"), id = try a.string("id"), version = try a.optional("version"), force = try a.flag("force")
            body = { service in
                let manager = try service.openManager()
                return try json(command == "installFromCatalog" ? manager.installFromCatalog(id: id, version: version, force: force) : manager.downloadFromCatalog(id: id, version: version))
            }
        case "link":
            let package = try args("package").string("package")
            body = { try json($0.openManager().link(package: package)) }
        case "update":
            let a = try args("id target reference detach"), id = try a.string("id"), target = try a.target(), detach = try a.flag("detach")
            body = { try json($0.openManager().update(id: id, target: target, detach: detach)) }
        case "updateAll", "updateAllPlan":
            _ = try args(); body = { service in
                let manager = try service.openManager()
                return try json(command == "updateAll" ? manager.updateAll() : manager.updateAllPlan())
            }
        case "enable", "disable", "forget":
            let a = try args("id force"), id = try a.string("id"), force = try a.flag("force")
            body = { service in
                let manager = try service.openManager()
                switch command {
                case "enable": return try json(manager.enable(id: id, force: force))
                case "disable": return try json(manager.disable(id: id, force: force))
                default: return try json(manager.forget(id: id, force: force))
                }
            }
        case "rollback", "restore", "uninstallPlan", "uninstallRefusal":
            let id = try args("id").string("id")
            body = { service in
                let manager = try service.openManager()
                switch command {
                case "rollback": return try json(manager.rollback(id: id))
                case "restore": return try json(manager.restore(id: id))
                case "uninstallPlan": return try json(manager.uninstallPlan(id: id))
                default: try Gitpm.uninstallRefusal(plan: manager.uninstallPlan(id: id)); return NSNull()
                }
            }
        case "uninstall":
            let a = try args("id confirmed force"), id = try a.string("id"), force = try a.flag("force")
            var confirmed: [LostWork] = []
            if let value = arguments["confirmed"] {
                guard let items = value as? [[String: Any]] else { throw invalid("confirmed must be an array of lost-work objects") }
                confirmed = try items.map(LostWork.argument)
            }
            let items = confirmed
            body = { try json($0.openManager().uninstall(id: id, confirmed: items, force: force)) }
        case "replace", "replacePlan", "replaceCheck", "replaceResolve":
            let a = try args("original replacement"), original = try a.string("original"), replacement = try a.string("replacement")
            body = { service in
                let manager = try service.openManager()
                switch command {
                case "replace": return try json(manager.replace(original: original, replacement: replacement))
                case "replacePlan": return try json(manager.replacePlan(original: original, replacement: replacement))
                case "replaceCheck": return try json(manager.replaceCheck(original: original, replacement: replacement))
                default: return try json(manager.replaceResolve(original: original, replacement: replacement))
                }
            }
        case "syncDist", "syncDistPlan":
            _ = try args(); body = { service in
                let manager = try service.openManager()
                return try json(command == "syncDist" ? manager.syncDist() : manager.syncDistPlan())
            }
        case "fork":
            let a = try args("id destination"), id = try a.string("id"), destination = try a.string("destination")
            body = { try json($0.openManager().fork(id: id, destination: destination)) }
        case "forkPackages", "forkSource":
            let a = try args(command == "forkSource" ? "ids destination source reference customSsh" : "ids destination"), ids = try a.strings("ids"), destination = try a.string("destination")
            let source = command == "forkSource" ? try a.string("source") : "", reference = try a.optional("reference"), ssh = try a.flag("customSsh")
            body = { service in
                if command == "forkSource" { return try json(Gitpm.forkSource(source: source, ids: ids, reference: reference, destination: destination, customSsh: ssh)) }
                return try json(service.openManager().forkPackages(ids: ids, destination: destination))
            }
        case "authCheck":
            let a = try args("source customSsh"), source = try a.string("source"), ssh = try a.flag("customSsh")
            body = { _ in try json(Gitpm.authCheck(source: source, customSsh: ssh)) }
        case "init":
            let a = try args("directory name multi release"), directory = try a.string("directory"), name = try a.string("name"), options = try InitOptions(multi: a.flag("multi"), release: a.flag("release", default: true))
            body = { _ in try json(Gitpm.`init`(directory: directory, name: name, options: options)) }
        case "commit":
            let a = try args("directory version package"), directory = try a.string("directory"), version = try a.string("version"), package = try a.optional("package")
            body = { _ in try json(Gitpm.commit(directory: directory, version: version, package: package)) }
        case "setRemote":
            let a = try args("directory url"), directory = try a.string("directory"), url = try a.string("url")
            body = { _ in try Gitpm.setRemote(directory: directory, url: url); return NSNull() }
        case "repositoryPackages":
            let directory = try args("directory").string("directory")
            body = { service in
                // The FFI's optional root enriches membership, but requires state.json.
                // Author repositories must also be inspectable before a workspace exists.
                let state = URL(fileURLWithPath: service.settings.root).appendingPathComponent("state.json").path
                let root = FileManager.default.fileExists(atPath: state) ? service.settings.root : nil
                return try json(Gitpm.repositoryPackages(directory: directory, root: root))
            }
        case "editDependency", "editRepositoryDependency":
            let a = try args(command == "editDependency" ? "id edit" : "directory package edit"), edit = try a.dependencyEdit()
            let directory = command == "editRepositoryDependency" ? try a.string("directory") : ""
            let id = command == "editDependency" ? try a.string("id") : "", package = command == "editRepositoryDependency" ? try a.string("package") : ""
            body = { service in
                if command == "editDependency" { return try json(service.openManager().editDependency(id: id, edit: edit)) }
                return try json(Gitpm.editDependency(directory: directory, package: package, edit: edit))
            }
        case "catalogUpdate":
            let a = try args("location sourcesFile customSsh"), location = try a.optional("location"), file = try a.string("sourcesFile"), ssh = try a.flag("customSsh")
            body = { service in
                guard let location = location ?? service.settings.catalog else { throw invalid("no catalog configured; supply location") }
                return try json(Gitpm.catalogUpdate(location: location, sourcesFile: file, customSsh: ssh))
            }
        case "catalogRegister":
            let a = try args("location source reference package build customSsh"), location = try a.optional("location"), source = try a.string("source"), reference = try a.string("reference"), package = try a.optional("package"), ssh = try a.flag("customSsh")
            var build: CatalogBuild?
            if arguments["build"] != nil, !(arguments["build"] is NSNull) {
                let b = try CommandArguments(a.object("build"), allowed: "url sha256")
                build = try CatalogBuild(url: b.string("url"), sha256: b.string("sha256"))
            }
            let artifact = build
            body = { service in
                guard let location = location ?? service.settings.catalog else { throw invalid("no catalog configured; supply location") }
                return try json(Gitpm.catalogRegister(location: location, source: source, reference: reference, package: package, build: artifact, customSsh: ssh))
            }
        case "describeLostWork":
            let item = try LostWork.argument(args("item").object("item"))
            body = { _ in Gitpm.describeLostWork(item: item) }
        default: throw invalid("unknown command \"\(command)\"")
        }
        return try await withCheckedThrowingContinuation { done in
            queue.async {
                do {
                    if gitCommands.contains(command) { try Self.requireGit() }
                    done.resume(returning: try body(self))
                } catch { done.resume(throwing: PluginManagerFailure.from(error)) }
            }
        }
    }
}
