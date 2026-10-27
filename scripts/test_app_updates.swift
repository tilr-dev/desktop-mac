import AppKit
import Sparkle
@testable import AppUpdates

final class HostDelegate: NSObject, SPUUpdaterDelegate {
    var finished = false
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finished = true
    }
}

@main struct UpdateTests {
    static func main() {
        _ = NSApplication.shared
        let mode = CommandLine.arguments[1]
        let suite = CommandLine.arguments[2]
        let arch = CommandLine.arguments[3]
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = UpdatePreferences(defaults: defaults, architecture: arch)
        let host = HostDelegate()
        let updates = AppUpdates(updaterDelegate: host, preferences: preferences)
        let updater = updates.controller.updater
        // Validate Sparkle configuration without entering its scheduled runloop cycle.
        try! updater.start()
        func expectFeed(_ beta: Bool) {
            let expected = "https://cdn.tilr.dev/mac/\(beta ? "beta/" : "")\(arch)/appcast.xml"
            precondition(updater.feedURL?.absoluteString == expected,
                         "Sparkle feed: \(String(describing: updater.feedURL)), expected \(expected)")
        }
        precondition(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
        precondition(ProcessInfo.processInfo.environment["TILR_UPDATE_FEED"] == "https://invalid.example/ignored.xml")
        if mode == "enable" {
            precondition(!preferences.receivesRCVersions)
            expectFeed(false)
            updates.showSettings()
            let panel = NSApp.windows.first { $0.title == "Update Settings" }!
            let stack = panel.contentView!.subviews.compactMap { $0 as? NSStackView }.first!
            let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
            let rc = buttons.first { $0.title == "Receive RC versions" }!
            precondition(rc.state == .off)
            rc.state = .on
            precondition(NSApp.sendAction(rc.action!, to: rc.target, from: rc))
            precondition(preferences.receivesRCVersions)
            expectFeed(true)
            // The adapter still advertises and forwards the host's About callbacks.
            let selector = #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:))
            let delegate: SPUUpdaterDelegate = UpdateFeedDelegate(preferences: preferences, host: host)
            precondition(delegate.responds(to: selector))
            delegate.updater?(updater, didFinishUpdateCycleFor: .updates, error: nil)
            precondition(host.finished)
            panel.close()
        } else if mode == "disable" {
            precondition(preferences.receivesRCVersions, "RC preference did not survive relaunch")
            expectFeed(true)
            preferences.receivesRCVersions = false
            expectFeed(false)
        } else {
            precondition(!preferences.receivesRCVersions, "Stable preference did not survive relaunch")
            expectFeed(false)
            defaults.removePersistentDomain(forName: suite)
        }
        print("Passed \(arch) \(mode)")
    }
}
