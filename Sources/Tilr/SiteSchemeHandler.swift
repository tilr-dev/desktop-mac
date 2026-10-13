import UniformTypeIdentifiers
import WebKit

/// Serves a directory to the web view as `tilr://<host>/...`, so a built SPA
/// (module scripts, fetch, absolute `/assets` paths) works the way it would
/// behind a web server — none of that is allowed from `file://`. The host is
/// ignored: each web view has its own handler, and the host (the app's name,
/// see Site.App) only keeps the apps' origins, and so their storage, apart.
///
/// Files are found and read on a private serial queue; WebKit hears back on the main queue,
/// and never about a task it has stopped (it raises on a call to a stopped task).
///
/// Known limits:
/// - No `Range` support: every response is the whole file. `<video>`/`<audio>`
///   from the site will not seek and may not play at all; add 206 handling if needed.
/// - The page is a secure context (`window.isSecureContext`, `navigator.clipboard`,
///   `crypto.subtle`): WebKit treats a scheme with a WKURLSchemeHandler as potentially
///   trustworthy (`schemeIsHandledBySchemeHandler` in SecurityOrigin.cpp). Verified in the
///   Mac app 2026-10-08.
final class SiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tilr"

    /// Changed when the config names another folder; the next request reads from there.
    var root: URL

    /// Where files are resolved and read, off the main thread.
    private let queue = DispatchQueue(label: "dev.tilr.site", qos: .userInitiated)
    /// Tasks started and neither finished nor stopped yet (main queue only).
    private var pending = Set<ObjectIdentifier>()

    init(root: URL) {
        self.root = root
    }

    private enum Reply {
        case file(HTTPURLResponse, Data)
        case failure(URLError)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        pending.insert(id)
        let root = root
        let url = task.request.url
        queue.async { [weak self] in
            let reply = Self.read(url, root: root)
            DispatchQueue.main.async {
                // Stopped meanwhile (a reload, a closed page): WebKit must not hear of it again.
                guard let self, self.pending.remove(id) != nil else { return }
                switch reply {
                case .file(let response, let data):
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                case .failure(let error):
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        pending.remove(ObjectIdentifier(task))
    }

    /// On `queue`: the response for `url` under `root`.
    private static func read(_ url: URL?, root: URL) -> Reply {
        guard let url, let file = resolve(url.path, root: root) else { return .failure(URLError(.fileDoesNotExist)) }
        // Mapped, so a large asset is not copied into memory up front.
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return .failure(URLError(.cannotOpenFile)) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mimeType(for: file.pathExtension),
            "Content-Length": String(data.count),
            // Files change underneath us; every reload must hit the disk.
            "Cache-Control": "no-store",
        ])!
        return .file(response, data)
    }

    /// Request path → file. A directory serves its `index.html`; an unknown
    /// extension-less path falls back to the root `index.html` for SPA routing.
    private static func resolve(_ path: String, root: URL) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains("..") else { return nil }
        let files = FileManager.default
        var file = parts.reduce(root) { $0.appendingPathComponent($1) }

        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: file.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { file.appendPathComponent("index.html") }
        } else if file.pathExtension.isEmpty {
            file = root.appendingPathComponent("index.html")
        }
        return files.fileExists(atPath: file.path) ? file : nil
    }

    /// The common web types, without a LaunchServices lookup per request.
    private static let knownTypes = [
        "html": "text/html", "htm": "text/html",
        "js": "text/javascript", "mjs": "text/javascript",
        "css": "text/css",
        "json": "application/json", "map": "application/json",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm",
        "txt": "text/plain", "md": "text/markdown",
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg",
        "mp4": "video/mp4", "webm": "video/webm",
        "pdf": "application/pdf",
    ]
    /// `UTType`'s answers for the other extensions. Shared by every tab's handler, each with its
    /// own queue, so guarded by `lookedUpLock`.
    private static var lookedUp: [String: String] = [:]
    private static let lookedUpLock = NSLock()

    private static func mimeType(for ext: String) -> String {
        let ext = ext.lowercased()
        if let known = knownTypes[ext] { return known }
        lookedUpLock.lock()
        defer { lookedUpLock.unlock() }
        if let cached = lookedUp[ext] { return cached }
        let type = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        lookedUp[ext] = type
        return type
    }
}
