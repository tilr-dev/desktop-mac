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
        var updateTimeout = 5.0
    }
}
final class Tab {
    struct App { var origin = URL(string: "tilr://app")! }
    var app = App()
    var webView = WKWebView()
}

@main struct LocalServerLifecycleTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        func expect(_ condition: Bool, line: UInt = #line) { precondition(condition, "line \(line)") }
        let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TILR_HOST_FIXTURE"]!)
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: state.appendingPathComponent(name))
        }
        func makeHome(_ name: String) throws -> (URL, URL) {
            let home = state.appendingPathComponent(name)
            let daemon = home.appendingPathComponent(".local/bin/tilrd")
            try fm.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            set -eu
            state="$TILR_HOST_FIXTURE"
            if [ "$1" = --version ]; then echo "tilrd $(cat "$state/installed") (macos-aarch64)"; exit; fi
            echo "$*" >> "$state/updates"
            test "$#" = 3
            test "$1" = update
            test "$2" = --channel
            if [ -f "$state/fail" ]; then echo 'daemon download failed' >&2; exit 7; fi
            case "$3" in
            stable) echo 0.9.1 > "$state/installed" ;;
            beta) echo 1.1.0-rc.2 > "$state/installed" ;;
            *) exit 9 ;;
            esac
            cp "$state/installed" "$state/running"
            rm -f "$state/incompatible"
            """
            try Data((script + "\n").utf8).write(to: daemon)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
            return (home, daemon)
        }
        func credentials(_ host: LocalServerHost) async throws -> [String: String]? {
            try await withCheckedThrowingContinuation { continuation in
                host.credentials { continuation.resume(with: $0) }
            }
        }
        try write("installed", "0.9.0\n")
        try write("token", "shared-token\n")
        let (home, daemon) = try makeHome("ordinary")
        var notices: [String] = []
        let host = LocalServerHost(homeDirectory: home, receiveNotice: {
            precondition(Thread.isMainThread, "Local Server notices must run on the main thread")
            notices.append($0)
        }, resolveRunningExecutable: { daemon })
        host.didUpdate = {
            precondition(Thread.isMainThread, "Local Server UI updates must run on the main thread")
        }
        var channel = "stable"
        host.updateChannel = {
            precondition(Thread.isMainThread, "Local Server update preferences must be read on the main thread")
            return channel
        }
        var settings = Config.LocalServer()
        host.start(settings: settings, origins: ["tilr://app"], allowed: true)
        let first = try await credentials(host)
        expect(first?["token"] == "shared-token")
        expect(host.status.contains("Installed tilrd: 0.9.0"))
        expect(host.status.contains("Please update tilrd: this application bundles 1.0.0."))
        settings.enabled = false
        host.configChanged(settings: settings, origins: ["tilr://app"], allowed: true)
        let disabled = try await credentials(host)
        expect(disabled == nil)
        settings.enabled = true
        host.configChanged(settings: settings, origins: ["tilr://app"], allowed: true)
        let reenabled = try await credentials(host)
        expect(reenabled == first)
        print("local server enable-disable-enable passed")
        let originalBytes = try Data(contentsOf: daemon)
        try write("fail", "")
        await host.updateTilrd()
        let afterFailure = try await credentials(host)
        expect(afterFailure == first)
        expect(host.status.contains("daemon download failed"))
        expect(notices.last == host.status)
        expect(try Data(contentsOf: daemon) == originalBytes)
        expect(try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8) == "shared-token\n")
        expect(!fm.fileExists(atPath: home.appendingPathComponent(".local/bin/.tilr-app-pending.json").path))
        try fm.removeItem(at: state.appendingPathComponent("fail"))
        await host.updateTilrd()
        expect(host.status.contains("Installed tilrd: 0.9.1"))
        expect(host.status.contains("Running tilrd: 0.9.1"))
        expect(host.status.contains("Please update tilrd:"))
        channel = "beta"
        await host.updateTilrd()
        expect(host.status.contains("Installed tilrd: 1.1.0-rc.2"))
        expect(host.status.contains("Running tilrd: 1.1.0-rc.2"))
        expect(!host.status.contains("Please update tilrd:"))
        let updates = try String(contentsOf: state.appendingPathComponent("updates"), encoding: .utf8)
        expect(updates == "update --channel stable\nupdate --channel stable\nupdate --channel beta\n")
        expect(try Data(contentsOf: daemon) == originalBytes)
        // Starting the stopped old daemon fails its first authenticated probe, then the
        // same update button recovers it without replacing it from the application bundle.
        try fm.removeItem(at: state.appendingPathComponent("running"))
        try write("installed", "0.8.0\n")
        try write("incompatible", "")
        let (oldHome, oldDaemon) = try makeHome("old-home")
        let oldBytes = try Data(contentsOf: oldDaemon)
        var protocolNotices: [String] = []
        let oldHost = LocalServerHost(homeDirectory: oldHome, receiveNotice: { protocolNotices.append($0) })
        oldHost.updateChannel = { "beta" }
        oldHost.start(settings: settings, origins: ["tilr://app"], allowed: true)
        do {
            _ = try await credentials(oldHost)
            fatalError("Expected incompatible protocol")
        } catch {
            expect(error.localizedDescription.contains("incompatible protocol"))
            expect(error.localizedDescription.contains("Update tilrd"))
        }
        expect(protocolNotices.last?.contains("incompatible protocol") == true)
        expect(protocolNotices.last?.components(separatedBy: "incompatible protocol").count == 2)
        expect(oldHost.status.contains("Installed tilrd: 0.8.0"))
        await oldHost.updateTilrd()
        let recovered = try await credentials(oldHost)
        expect(recovered == first)
        expect(oldHost.status.contains("Running tilrd: 1.1.0-rc.2"))
        expect(try Data(contentsOf: oldDaemon) == oldBytes)
        expect(!fm.fileExists(atPath: oldHome.appendingPathComponent(".local/bin/.tilr-app-pending.json").path))
        print("local server daemon updates and protocol recovery passed")
    }
}
