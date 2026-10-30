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
            if [ -f "$state/upgrade-protocol" ]; then touch "$state/newer"; fi
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
        var reconnects = 0
        host.didUpdate = {
            precondition(Thread.isMainThread, "Local Server UI updates must run on the main thread")
            reconnects += 1
        }
        var channel = "stable"
        host.updateChannel = {
            precondition(Thread.isMainThread, "Local Server update preferences must be read on the main thread")
            return channel
        }
        func updates() -> String {
            (try? String(contentsOf: state.appendingPathComponent("updates"), encoding: .utf8)) ?? ""
        }
        var settings = Config.LocalServer()
        // Launch serves the installed daemon at once, then updates it to the latest release.
        host.start(settings: settings, origins: ["tilr://app"], allowed: true)
        let first = try await credentials(host)
        expect(first?["token"] == "shared-token")
        await host.waitForLaunchUpdate()
        expect(updates() == "update --channel stable\n")
        expect(host.status.contains("Installed tilrd: 0.9.1"))
        expect(host.status.contains("Running tilrd: 0.9.1"))
        expect(!host.status.contains("Please update tilrd"))
        expect(try await credentials(host) == first)
        expect(reconnects == 1 && notices.isEmpty)
        settings.enabled = false
        host.configChanged(settings: settings, origins: ["tilr://app"], allowed: true)
        let disabled = try await credentials(host)
        expect(disabled == nil)
        settings.enabled = true
        host.configChanged(settings: settings, origins: ["tilr://app"], allowed: true)
        let reenabled = try await credentials(host)
        expect(reenabled == first)
        // The latest release is already running: nothing changes and pages do not reconnect.
        await host.waitForLaunchUpdate()
        expect(updates() == "update --channel stable\nupdate --channel stable\n")
        expect(host.status.contains("Running tilrd: 0.9.1"))
        expect(reconnects == 1 && notices.isEmpty)
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
        // An unreachable CDN at launch keeps the installed daemon and only reports it.
        var offlineNotices: [String] = []
        let offline = LocalServerHost(homeDirectory: home, receiveNotice: { offlineNotices.append($0) },
                                      resolveRunningExecutable: { daemon })
        offline.start(settings: settings, origins: ["tilr://app"], allowed: true)
        expect(try await credentials(offline) == first)
        await offline.waitForLaunchUpdate()
        expect(offline.status.contains("Running tilrd: 0.9.1"))
        expect(offline.status.contains("Could not update tilrd at launch: tilrd update failed: daemon download failed"))
        expect(try await credentials(offline) == first)
        expect(offlineNotices.isEmpty)
        try fm.removeItem(at: state.appendingPathComponent("fail"))
        channel = "beta"
        await host.updateTilrd()
        expect(host.status.contains("Installed tilrd: 1.1.0-rc.2"))
        expect(host.status.contains("Running tilrd: 1.1.0-rc.2"))
        expect(reconnects == 2)
        expect(updates().hasSuffix("update --channel stable\nupdate --channel stable\nupdate --channel beta\n"))
        expect(try Data(contentsOf: daemon) == originalBytes)
        // Starting the stopped old daemon fails its first authenticated probe; the launch
        // update recovers it through the daemon's own update, not from the application bundle.
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
            expect(error.localizedDescription.contains("tilrd speaks protocol 0 and this Tilr supports protocol 1: update tilrd in Local Server."))
        }
        expect(protocolNotices.last?.contains("speaks protocol 0") == true)
        expect(protocolNotices.last?.components(separatedBy: "the server speaks protocol 0").count == 2)
        await oldHost.waitForLaunchUpdate()
        let recovered = try await credentials(oldHost)
        expect(recovered == first)
        expect(oldHost.status.contains("Running tilrd: 1.1.0-rc.2"))
        expect(try Data(contentsOf: oldDaemon) == oldBytes)
        expect(!fm.fileExists(atPath: oldHome.appendingPathComponent(".local/bin/.tilr-app-pending.json").path))
        // A daemon newer than the application asks for a Tilr update and is not updated.
        try write("newer", "")
        let beforeNewer = updates()
        var newerNotices: [String] = []
        let newerHost = LocalServerHost(homeDirectory: oldHome, receiveNotice: { newerNotices.append($0) },
                                        resolveRunningExecutable: { oldDaemon })
        newerHost.start(settings: settings, origins: ["tilr://app"], allowed: true)
        do {
            _ = try await credentials(newerHost)
            fatalError("Expected a newer protocol")
        } catch {
            expect(error.localizedDescription.contains("tilrd speaks protocol 2 and this Tilr supports protocol 1: update Tilr."))
        }
        await newerHost.waitForLaunchUpdate()
        expect(updates() == beforeNewer)
        expect(newerNotices.last?.contains("update Tilr.") == true)
        try fm.removeItem(at: state.appendingPathComponent("newer"))
        // A launch update that installs a newer protocol tells the user to update Tilr.
        try write("upgrade-protocol", "")
        let (upgradeHome, upgradeDaemon) = try makeHome("protocol-upgrade")
        var upgradeNotices: [String] = []
        let upgradeHost = LocalServerHost(homeDirectory: upgradeHome, receiveNotice: { upgradeNotices.append($0) },
                                          resolveRunningExecutable: { upgradeDaemon })
        upgradeHost.updateChannel = { "stable" }
        upgradeHost.start(settings: settings, origins: ["tilr://app"], allowed: true)
        expect(try await credentials(upgradeHost) == first)
        expect(upgradeNotices.isEmpty)
        await upgradeHost.waitForLaunchUpdate()
        expect(upgradeNotices.count == 1)
        expect(upgradeNotices.last?.contains("tilrd speaks protocol 2 and this Tilr supports protocol 1: update Tilr.") == true)
        do {
            _ = try await credentials(upgradeHost)
            fatalError("Expected a newer protocol after the launch update")
        } catch {
            expect(error.localizedDescription.contains("update Tilr."))
        }
        try fm.removeItem(at: state.appendingPathComponent("upgrade-protocol"))
        try fm.removeItem(at: state.appendingPathComponent("newer"))
        print("local server daemon updates and protocol recovery passed")
    }
}
