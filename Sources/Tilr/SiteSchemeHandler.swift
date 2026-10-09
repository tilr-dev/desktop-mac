import UniformTypeIdentifiers
import WebKit

/// Serves a directory to the web view as `tilr://<host>/...`, so a built SPA
/// (module scripts, fetch, absolute `/assets` paths) works the way it would
/// behind a web server — none of that is allowed from `file://`. The host is
/// ignored: each web view has its own handler, and the host (the app's name,
/// see Site.App) only keeps the apps' origins, and so their storage, apart.
///
/// Known limits:
/// - No `Range` support: every response is the whole file. `<video>`/`<audio>`
///   from the site will not seek and may not play at all; add 206 handling if needed.
/// - Files are read synchronously on the main thread, so a huge asset stalls the UI.
/// - The page is a secure context (`window.isSecureContext`, `navigator.clipboard`,
///   `crypto.subtle`): WebKit treats a scheme with a WKURLSchemeHandler as potentially
///   trustworthy (`schemeIsHandledBySchemeHandler` in SecurityOrigin.cpp). Verified in the
///   Mac app 2026-10-08.
final class SiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tilr"

    /// Changed when the config names another folder; the next request reads from there.
    var root: URL

    init(root: URL) {
        self.root = root
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = resolve(url.path) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        // Mapped, so a large asset is not copied into memory up front.
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return task.didFailWithError(URLError(.cannotOpenFile))
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.mimeType(for: file.pathExtension),
            "Content-Length": String(data.count),
            // Files change underneath us; every reload must hit the disk.
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Request path → file. A directory serves its `index.html`; an unknown
    /// extension-less path falls back to the root `index.html` for SPA routing.
    private func resolve(_ path: String) -> URL? {
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

    private static let extraTypes = [
        "mjs": "text/javascript",
        "wasm": "application/wasm",
        "map": "application/json",
        "woff2": "font/woff2",
    ]

    private static func mimeType(for ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType
            ?? extraTypes[ext.lowercased()]
            ?? "application/octet-stream"
    }
}
