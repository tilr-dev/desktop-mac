import AppKit
import WebKit

/// The page's web views (the `webviews` plugin of the web repo, its native backend): a WKWebView
/// per view, a subview of the tab's web view, placed where the page says the view's host element
/// is. The page posts `{ op, id, … }` to `webkit.messageHandlers.tilrWebViews`:
///
///   create   url            a new view, loading `url`
///   place    x y width height visible   the host's rect in the page (CSS px, from the top left)
///   navigate url
///   back | forward | reload | stop
///   dispose
///
/// and the app answers with a `tilr-webview` CustomEvent on the page's `window`, `detail` being
/// `{ id, url, title, loading, progress, canGoBack, canGoForward, error }` on every change of the
/// view's state, or `{ id, type: 'open', open: url }` when the view's page asks for a new
/// window (`target=_blank`, `window.open`). Views go when the page navigates (a reload), and
/// with the tab. A view is above the page: what the page draws over its host is covered.
final class WebViewHost: NSObject, WKScriptMessageHandler {
    static let name = "tilrWebViews"
    static let event = "tilr-webview"

    weak var tab: Tab?
    /// `browser:` in the config; read when a view is made.
    var settings: Config.Browser
    private var views: [String: ChildView] = [:]

    init(settings: Config.Browser) {
        self.settings = settings
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, let body = message.body as? [String: Any], let op = body["op"] as? String, let id = body["id"] as? String else { return }
        switch op {
        case "create":
            views[id]?.remove()
            let view = ChildView(id: id, settings: settings, parent: tab.webView) { [weak tab] detail in
                tab?.send(event: WebViewHost.event, detail: detail)
            }
            views[id] = view
            view.load(body["url"] as? String ?? "about:blank")
        case "place":
            guard let x = body["x"] as? Double, let y = body["y"] as? Double, let width = body["width"] as? Double, let height = body["height"] as? Double else { return }
            views[id]?.place(CGRect(x: x, y: y, width: width, height: height), visible: body["visible"] as? Bool ?? true)
        case "navigate":
            views[id]?.load(body["url"] as? String ?? "about:blank")
        case "back": views[id]?.webView.goBack()
        case "forward": views[id]?.webView.goForward()
        case "reload": views[id]?.webView.reload()
        case "stop": views[id]?.webView.stopLoading()
        case "dispose":
            views[id]?.remove()
            views[id] = nil
        default:
            print("webviews: unknown op \(op)")
        }
    }

    /// The page is going (a reload, the tab closing): every view with it.
    func removeAll() {
        for view in views.values { view.remove() }
        views.removeAll()
    }
}

/// One view: the WKWebView, its place, and the reports to the page. KVO on the web view's
/// url / title / loading / progress / history, coalesced into one report per run of the loop.
final class ChildView: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let webView: WKWebView
    private weak var parent: NSView?
    private let report: ([String: Any]) -> Void
    private var observers: [NSKeyValueObservation] = []
    private var error: String?
    private var pending = false

    init(id: String, settings: Config.Browser, parent: NSView, report: @escaping ([String: Any]) -> Void) {
        self.id = id
        self.parent = parent
        self.report = report
        let configuration = WKWebViewConfiguration()
        // The default store: cookies and logins shared by every view, kept across launches.
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        if !settings.userAgent.isEmpty { webView.customUserAgent = settings.userAgent }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.isHidden = true
        webView.underPageBackgroundColor = .white
        parent.addSubview(webView)
        let changed: (WKWebView, Any) -> Void = { [weak self] _, _ in self?.schedule() }
        observers = [
            webView.observe(\.url, changeHandler: changed),
            webView.observe(\.title, changeHandler: changed),
            webView.observe(\.isLoading, changeHandler: changed),
            webView.observe(\.estimatedProgress, changeHandler: changed),
            webView.observe(\.canGoBack, changeHandler: changed),
            webView.observe(\.canGoForward, changeHandler: changed),
        ]
    }

    func load(_ text: String) {
        guard let url = URL(string: text) else {
            error = "not a URL: \(text)"
            schedule()
            return
        }
        error = nil
        webView.load(URLRequest(url: url))
    }

    /// `rect` is the host's place in the page: CSS px from the top left, which is the web view's
    /// coordinate system (WKWebView is flipped on macOS; the check keeps it right either way).
    func place(_ rect: CGRect, visible: Bool) {
        guard let parent else { return }
        let y = parent.isFlipped ? rect.minY : parent.bounds.height - rect.minY - rect.height
        webView.frame = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
        webView.isHidden = !visible
    }

    func remove() {
        observers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    // MARK: Reports

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.report(self.state)
        }
    }

    private var state: [String: Any] {
        [
            "id": id,
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
            "loading": webView.isLoading,
            "progress": webView.estimatedProgress,
            "canGoBack": webView.canGoBack,
            "canGoForward": webView.canGoForward,
            "error": error ?? NSNull(),
        ]
    }

    private func failed(_ error: Error) {
        let nsError = error as NSError
        // A load replaced by the next one, or stopped by the policy (a link handed to the system),
        // is not a failure. 102: WKErrorFrameLoadInterruptedByPolicyChange.
        guard nsError.code != NSURLErrorCancelled, !(nsError.domain == WKError.errorDomain && nsError.code == 102) else { return }
        self.error = error.localizedDescription
        schedule()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        schedule()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// Links to other apps (mailto:, a custom scheme) go to the system; the web stays here.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.allow) }
        if ["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme) { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: WKUIDelegate

    /// A new window: the page decides where it goes (a new browser window, or this view).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString, !url.isEmpty, url != "about:blank" {
            report(["id": id, "type": "open", "open": url])
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? ""
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? ""
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? ""
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
