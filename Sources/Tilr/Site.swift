import Foundation

/// The local folder the app shows — the Mac counterpart of the iPad app's Documents.
/// `--site DIR` picks another one; `--url URL` or TILR_URL skips it for a dev server.
enum Site {
    static let root: URL = {
        if let dir = argument("--site") { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tilr-mac", isDirectory: true)
    }()

    static let devURL: URL? = (argument("--url") ?? ProcessInfo.processInfo.environment["TILR_URL"])
        .flatMap(URL.init(string:))

    /// Copies the bundled starter files in when `index.html` is missing (first launch, or
    /// someone deleted it). Files already in the folder are left alone.
    static func seed() {
        let files = FileManager.default
        guard !files.fileExists(atPath: root.appendingPathComponent("index.html").path),
              let bundled = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
              let names = try? files.contentsOfDirectory(atPath: bundled.path)
        else { return }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names where !files.fileExists(atPath: root.appendingPathComponent(name).path) {
            try? files.copyItem(at: bundled.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
