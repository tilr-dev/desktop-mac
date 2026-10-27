import AppKit
import WebKit

// Minimal surrounding app types: this fixture executes the production host and bridge.
struct Config {
    struct LocalServer {
        var enabled = true
        var port: UInt16 = 7890
        var commandTimeout = 5.0
        var startupTimeout = 5.0
        var retryInterval = 0.25
        var updateChannel = "stable"
        var autoCheck = false
        var checkInterval = 86400.0
        var downloadTimeout = 5.0
        var maxFeedBytes: Int64 = 1048576
        var maxDownloadBytes: Int64 = 1048576
    }
}
final class Tab {
    struct App { var origin = URL(string: "tilr://app")! }
    var app = App()
    var webView = WKWebView()
}

@main struct LocalServerLifecycleTests {
    @MainActor static func main() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tilr-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let host = LocalServerHost(homeDirectory: temp)
        var settings = Config.LocalServer()
        func credentials() async throws -> [String: String]? {
            try await withCheckedThrowingContinuation { continuation in
                host.credentials { continuation.resume(with: $0) }
            }
        }
        host.start(settings: settings, origins: ["tilr://app"], allowed: true)
        let first = try await credentials()
        precondition(first?["token"] == "shared-token")
        settings.enabled = false
        host.configChanged(settings: settings, origins: ["tilr://app"], allowed: true)
        let disabled = try await credentials()
        precondition(disabled == nil)
        settings.enabled = true
        host.configChanged(settings: settings, origins: ["tilr://app"], allowed: true)
        let reenabled = try await credentials()
        precondition(reenabled?["token"] == first?["token"])
        print("local server enable-disable-enable passed")
    }
}
