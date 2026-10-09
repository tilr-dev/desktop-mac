import Foundation

/// Where the pages come from. An app is a folder with an `index.html`, shown in a window of its
/// own as `tilr://<name>/` (SiteSchemeHandler); distinct origins keep the apps' localStorage
/// apart. The list: `--site DIR` (a single app), else `apps:` in the config, else `site:` in the
/// config, else `~/tilr`. `--url URL` or TILR_URL shows a dev server in a single window instead.
enum Site {
    struct App: Equatable {
        let name: String
        let root: URL

        /// Host of the app's origin: `My Notes` → `tilr://my-notes/`. ASCII only, so it is a valid URL host.
        var host: String {
            let slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return trimmed.isEmpty ? "app" : trimmed
        }

        var origin: URL { URL(string: "\(SiteSchemeHandler.scheme)://\(host)/")! }
    }

    static let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tilr", isDirectory: true)

    static let devURL: URL? = (argument("--url") ?? ProcessInfo.processInfo.environment["TILR_URL"])
        .flatMap(URL.init(string:))

    /// The apps to show, in window order. Never empty.
    static func apps(config: Config) -> [App] {
        if let dir = argument("--site") { return [App(name: "app", root: folder(dir))] }
        if devURL != nil { return [App(name: "app", root: fallback)] }
        if !config.apps.isEmpty { return config.apps.map { App(name: $0.name, root: folder($0.site)) } }
        return [App(name: "app", root: folder(config.site))]
    }

    static func hasIndex(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
    }

    /// The bundled page shown while the site folder has no `index.html`; it names the folder.
    static func placeholder(for root: URL) -> URL {
        // fileURLWithPath makes it absolute: the bundle URL is relative when the binary was run by a relative path.
        let file = URL(fileURLWithPath: Bundle.main.resourceURL!.appendingPathComponent("placeholder.html").path)
        var parts = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "site", value: root.path)]
        return parts.url!
    }

    /// `~` expanded, as a directory URL.
    private static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
