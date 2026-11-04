import Foundation
import WebKit

/// Promise replies are scoped by WebKit to the requesting page, without a global response event.
final class ConfigBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "tilrConfig"
    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab, message.frameInfo.isMainFrame, message.webView === tab.webView,
              message.frameInfo.securityOrigin.protocol == "tilr",
              message.frameInfo.securityOrigin.host == tab.app.origin.host else {
            replyHandler(nil, "Config access is restricted to the Tilr app page.")
            return
        }
        do {
            replyHandler(try Self.handle(message.body, files: ConfigFiles(directory: Config.dir)), nil)
        } catch { replyHandler(nil, error.localizedDescription) }
    }

    static func handle(_ message: Any, files: ConfigFiles) throws -> Any {
        guard let body = message as? [String: Any], let op = body["op"] as? String,
              let name = body["name"] as? String else {
            throw ConfigFiles.Failure(message: "Config request requires op and filename.")
        }
        switch op {
        case "read": return try files.read(name) as Any? ?? NSNull()
        case "write":
            guard let text = body["text"] as? String else {
                throw ConfigFiles.Failure(message: "Config write requires text.")
            }
            try files.write(name, text: text)
            return ["ok": true]
        default: throw ConfigFiles.Failure(message: "Unknown config operation: \(op).")
        }
    }
}
