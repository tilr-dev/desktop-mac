import Foundation

// The plugin manager (Rust, ../../plugin-manager) for the app. UniFFI's generated API
// (Generated/Gitpm.swift: PluginManager, InstalledPlugin, UninstallPlan, …)
// blocks on Git and the network; this file runs it on a queue of its own and hands back
// async results. Records come through as generated (public); errors become
// `PluginManagerFailure`. No UI here.

/// A plugin manager error: `kind` is the library's stable snake_case identifier
/// (`not_installed`, `locked`, `git`, … — see the library's README), `message` its complete
/// human text. `id` names the plugin when the library says which; `lostWork` lists what an
/// uninstall would discard (`local_changes`); `plugins` names the dependents that block a
/// removal (`has_dependents`) or the consumers a replacement would not satisfy
/// (`incompatible_replacement`).
public struct PluginManagerFailure: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let kind: String
    public let message: String
    public let id: String?
    public let lostWork: [LostWork]
    public let plugins: [String]

    public init(kind: String, message: String, id: String? = nil, lostWork: [LostWork] = [], plugins: [String] = []) {
        self.kind = kind
        self.message = message
        self.id = id
        self.lostWork = lostWork
        self.plugins = plugins
    }

    public var errorDescription: String? { message }
    public var description: String { "\(kind): \(message)" }

    /// Any error out of the generated API (or ours) as a failure with a kind.
    public static func from(_ error: Error) -> PluginManagerFailure {
        if let failure = error as? PluginManagerFailure { return failure }
        guard let error = error as? PmError else {
            // UniFFI's own errors (a Rust panic, a bad buffer): a bug, not a user condition.
            return PluginManagerFailure(kind: "internal", message: String(describing: error))
        }
        switch error {
        case .NotInstalled(let id, let message): return .init(kind: "not_installed", message: message, id: id)
        case .AlreadyInstalled(let id, let message): return .init(kind: "already_installed", message: message, id: id)
        case .LocalChanges(let id, let message, let items): return .init(kind: "local_changes", message: message, id: id, lostWork: items)
        case .Locked(let message): return .init(kind: "locked", message: message)
        case .InvalidId(let message): return .init(kind: "invalid_id", message: message)
        case .InvalidManifest(let message): return .init(kind: "invalid_manifest", message: message)
        case .InvalidVersion(let message): return .init(kind: "invalid_version", message: message)
        case .InvalidArgument(let message): return .init(kind: "invalid_argument", message: message)
        case .VersionConflict(let message): return .init(kind: "version_conflict", message: message)
        case .NoPreviousVersion(let id, let message): return .init(kind: "no_previous_version", message: message, id: id)
        case .NoReleases(let message): return .init(kind: "no_releases", message: message)
        case .RepositoryNotFound(let id, let message): return .init(kind: "repository_not_found", message: message, id: id)
        case .Workspace(let message): return .init(kind: "workspace", message: message)
        case .Catalog(let message): return .init(kind: "catalog", message: message)
        case .Git(let message): return .init(kind: "git", message: message)
        case .Http(let message): return .init(kind: "http", message: message)
        case .Auth(let message): return .init(kind: "auth", message: message)
        case .Unsupported(let message): return .init(kind: "unsupported", message: message)
        case .DependencyConflict(let message): return .init(kind: "dependency_conflict", message: message)
        case .HasDependents(let id, let message, let dependents):
            return .init(kind: "has_dependents", message: message, id: id, plugins: dependents)
        case .IncompatibleReplacement(let id, let message, let consumers):
            return .init(kind: "incompatible_replacement", message: message, id: id, plugins: consumers)
        case .InvalidData(let message): return .init(kind: "invalid_data", message: message)
        case .Io(let message): return .init(kind: "io", message: message)
        case .Other(let kind, let message): return .init(kind: kind, message: message)
        }
    }
}

/// One workspace of the plugin manager, opened lazily on the first operation and kept open
/// (it holds the workspace's lock) until `configure` names another workspace or catalog, or
/// `close()`. Every operation runs on the service's serial queue, never on the caller's
/// thread; the library serializes them too.
public final class PluginManagerService: @unchecked Sendable {
    public struct Settings: Equatable, Sendable {
        /// The workspace folder (absolute; made on open).
        public var root: String
        /// Catalog location: local folder, JSON file or HTTP(S) URL; nil: none.
        public var catalog: String?
        public init(root: String, catalog: String?) {
            self.root = root
            self.catalog = catalog
        }
    }

    private let queue: DispatchQueue
    // Only touched on `queue`.
    private var settings: Settings
    private var manager: PluginManager?

    public init(settings: Settings, label: String = "dev.tilr.plugin-manager") {
        self.settings = settings
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Takes effect for the next operation; a changed workspace or catalog closes the open
    /// manager (releasing its lock) so the next operation opens the new one.
    public func configure(_ new: Settings) {
        queue.async {
            guard new != self.settings else { return }
            self.settings = new
            self.manager = nil
        }
    }

    /// Releases the workspace (and its lock); the next operation opens it again.
    public func close() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.manager = nil
                done.resume()
            }
        }
    }

    /// The settings in use and whether the workspace is open now.
    public func status() async -> (settings: Settings, open: Bool) {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: (self.settings, self.manager != nil)) }
        }
    }

    /// Opens (or creates) the workspace now: `locked` when another process (or another
    /// service in this one) holds it.
    public func open() async throws {
        try await run { _ in () }
    }

    public func root() async throws -> String { try await run { $0.root() } }
    public func list() async throws -> [InstalledPlugin] { try await run { try $0.list() } }
    /// Installed versions against the configured catalog (read-only).
    public func check() async throws -> [CheckRow] { try await run { try $0.check() } }
    public func browseCatalog() async throws -> CatalogOverview { try await run { try $0.browseCatalog() } }
    /// A release from the configured catalog; the latest when `version` is nil.
    public func catalogRelease(id: String, version: String? = nil) async throws -> CatalogRelease {
        try await run { try $0.catalogRelease(id: id, version: version) }
    }
    /// From a Git source (URL or local path): the latest release tag, `reference`, or the
    /// branch head with `.dev`.
    public func install(source: String, reference: String? = nil, channel: Channel = .stable) async throws -> InstallResult {
        try await run(git: true) { try $0.install(source: source, reference: reference, channel: channel) }
    }
    /// An exact catalog release (latest when `version` is nil), hashes verified.
    public func installFromCatalog(id: String, version: String? = nil) async throws -> InstallResult {
        try await run(git: true) { try $0.installFromCatalog(id: id, version: version) }
    }
    public func update(id: String, reference: String? = nil, channel: Channel = .stable) async throws -> RevisionChange {
        try await run(git: true) { try $0.update(id: id, reference: reference, channel: channel) }
    }
    public func rollback(id: String) async throws -> RevisionChange { try await run(git: true) { try $0.rollback(id: id) } }
    public func enable(id: String) async throws { try await run { try $0.enable(id: id) } }
    /// `has_dependents` while other installed plugins need it, unless `force`.
    public func disable(id: String, force: Bool = false) async throws { try await run { try $0.disable(id: id, force: force) } }
    /// Unregisters; the repository and its files stay on disk (`restore` brings it back).
    /// `has_dependents` while other installed plugins need it, unless `force`.
    public func forget(id: String, force: Bool = false) async throws { try await run { try $0.forget(id: id, force: force) } }
    public func restore(id: String) async throws -> InstallResult { try await run(git: true) { try $0.restore(id: id) } }
    /// What `uninstall` would delete, the local work it would lose and the installed plugins
    /// that depend on it (read-only; reads the clone with git).
    public func uninstallPlan(id: String) async throws -> UninstallPlan { try await run(git: true) { try $0.uninstallPlan(id: id) } }
    /// `confirm: false` refuses with `local_changes` when anything would be lost; dependents
    /// refuse with `has_dependents` unless `force`.
    public func uninstall(id: String, confirm: Bool, force: Bool = false) async throws {
        try await run(git: true) { try $0.uninstall(id: id, confirm: confirm, force: force) }
    }
    /// What making `replacement` the provider of `original` for every consumer would change.
    public func replacePlan(original: String, replacement: String) async throws -> ReplacementPlan {
        try await run { try $0.replacePlan(original: original, replacement: replacement) }
    }
    /// Global replacement. `incompatible_replacement` (consumers in `plugins`) unless `confirm`.
    public func replace(original: String, replacement: String, confirm: Bool) async throws -> ReplacementPlan {
        try await run { try $0.replace(original: original, replacement: replacement, confirm: confirm) }
    }
    public func switchBackPlan(original: String) async throws -> ReplacementPlan {
        try await run { try $0.switchBackPlan(original: original) }
    }
    /// Every consumer uses the installed original again (same confirmation rule as replace).
    public func switchBack(original: String, confirm: Bool) async throws -> ReplacementPlan {
        try await run { try $0.switchBack(original: original, confirm: confirm) }
    }
    /// Forks an installed plugin into `namespace` at `destination` (outside the workspace).
    public func fork(id: String, destination: String, namespace: String) async throws -> ForkResult {
        try await run(git: true) { try $0.fork(id: id, destination: destination, namespace: namespace) }
    }

    // Free functions: no workspace, no lock; still off the caller's thread.

    /// Read access to a Git repository with the user's credentials (`git ls-remote`).
    public func authCheck(source: String, customSSH: Bool = false) async throws -> AuthCheck {
        try await detached(git: true) { try Gitpm.authCheck(source: source, customSsh: customSSH) }
    }
    /// An overview of any catalog location.
    public func browseCatalog(location: String) async throws -> CatalogOverview {
        try await detached { try Gitpm.browseCatalog(location: location) }
    }
    public func catalogRelease(location: String, id: String, version: String? = nil) async throws -> CatalogRelease {
        try await detached { try Gitpm.catalogRelease(location: location, id: id, version: version) }
    }
    /// The installed plugins of a workspace without opening (locking or creating) it.
    public func readInstalled(root: String) async throws -> [InstalledPlugin] {
        try await detached { try Gitpm.readInstalled(root: root) }
    }
    /// One line for a lost-work item, for a confirmation.
    public static func describe(_ item: LostWork) -> String { describeLostWork(item: item) }

    // MARK: Git

    /// Why the system `git` the library runs cannot start, or nil when it can. The library
    /// needs it for now (clone, fetch, status); a Mac without the Xcode Command Line Tools has
    /// only /usr/bin/git, a stub that asks to install them, so that stub is not run here:
    /// `xcode-select -p` says whether the tools are there. Blocking (a subprocess): call off the
    /// main thread.
    public static func gitProblem() -> String? {
        let install = "install the Xcode Command Line Tools (xcode-select --install) or git"
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let files = FileManager.default
        guard let git = path.split(separator: ":").map({ "\($0)/git" }).first(where: { files.isExecutableFile(atPath: $0) }) else {
            return "git is not installed; \(install)"
        }
        guard git == "/usr/bin/git" else { return nil }
        let select = Process()
        select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        select.arguments = ["-p"]
        let output = Pipe()
        select.standardOutput = output
        select.standardError = FileHandle.nullDevice
        do { try select.run() } catch { return "git is not installed (no xcode-select); \(install)" }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        select.waitUntilExit()
        guard select.terminationStatus == 0, !text.isEmpty, files.fileExists(atPath: text) else {
            return "git is not installed (/usr/bin/git is only the installer stub); \(install)"
        }
        return nil
    }

    private static func requireGit() throws {
        if let problem = gitProblem() { throw PluginManagerFailure(kind: "git", message: problem) }
    }

    // MARK: Plumbing

    /// Runs `body` with the open manager on the queue, opening it first when needed.
    private func run<T>(git: Bool = false, _ body: @escaping (PluginManager) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            queue.async {
                do {
                    if git { try Self.requireGit() }
                    let manager: PluginManager
                    if let open = self.manager {
                        manager = open
                    } else {
                        manager = try PluginManager.open(root: self.settings.root,
                                                         options: ManagerOptions(catalog: self.settings.catalog))
                        self.manager = manager
                    }
                    done.resume(returning: try body(manager))
                } catch {
                    done.resume(throwing: PluginManagerFailure.from(error))
                }
            }
        }
    }

    /// A blocking call that needs no workspace, on a global queue (not behind a long install).
    private func detached<T>(git: Bool = false, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if git { try Self.requireGit() }
                    done.resume(returning: try body())
                } catch { done.resume(throwing: PluginManagerFailure.from(error)) }
            }
        }
    }
}
