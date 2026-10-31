import AppKit
import Sparkle
@testable import AppUpdates

final class HostDelegate: NSObject, SPUUpdaterDelegate {
    var finished = false
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finished = true
    }
}

// Sparkle has no public way to seed a deferred update. KVC is confined to this
// fixture for the pinned version; production code uses only the public lifecycle API.
final class DeferredUpdate: NSObject {
    @objc let updateItem = SUAppcastItem(dictionary: ["sparkle:version": "999", "link": "https://tilr.dev/rc"])!
    @objc var secondaryUpdateItem: SUAppcastItem? { nil }
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
        let menuItem = NSMenuItem(title: "Check for Updates…",
                                  action: #selector(AppUpdates.checkForUpdates(_:)), keyEquivalent: "")
        menuItem.target = updates
        func expectMenuEnabled(_ enabled: Bool) {
            let validator = menuItem.target as? NSMenuItemValidation
            precondition(validator != nil, "Update menu target must preserve Sparkle validation")
            precondition(validator!.validateMenuItem(menuItem) == enabled)
        }
        updater.setValue(true, forKey: "canCheckForUpdates")
        expectMenuEnabled(true)
        updater.setValue(false, forKey: "canCheckForUpdates")
        expectMenuEnabled(false)
        func expectFeed(_ beta: Bool) {
            let expected = "https://cdn.tilr.dev/mac/\(beta ? "beta/" : "")\(arch)/appcast.xml"
            precondition(updates.controller.updater.feedURL?.absoluteString == expected,
                         "Sparkle feed: \(String(describing: updater.feedURL)), expected \(expected)")
        }
        precondition(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
        precondition(ProcessInfo.processInfo.environment["TILR_UPDATE_FEED"] == "https://invalid.example/ignored.xml")
        if mode == "display" {
            let about = About()
            about.show(appUpdates: nil, pluginStatus: [])
            let panel = NSApp.windows.first { $0.title == "About Tilr" }!
            let stack = panel.contentView!.subviews.compactMap { $0 as? NSStackView }.first!
            func texts() -> [String] {
                stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
            }
            precondition(texts().contains("Installed: \(CommandLine.arguments[4]) (build 1)"))
            for (title, expected) in [("Tilr 0.1.0-rc.2", "0.1.0-rc.2"),
                                      ("Tilr 0.1.0", "0.1.0"), ("Legacy release", "0.1.0"),
                                      ("", "0.1.0"), ("Tilr 9.9.9-rc.1", "0.1.0")] {
                let item = SUAppcastItem(dictionary: ["title": title, "sparkle:version": "2",
                    "sparkle:shortVersionString": "0.1.0", "link": "https://tilr.dev/release"])!
                precondition(item.displayVersionString == "0.1.0" && item.versionString == "2")
                precondition(SUStandardVersionComparator.default.compareVersion(item.versionString, toVersion: "1") == .orderedDescending)
                about.updater(updater, didFindValidUpdate: item)
                precondition(texts().contains("Available: \(expected) (build 2)"))
                let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                    userInfo: [SPULatestAppcastItemFoundKey: item, NSLocalizedDescriptionKey: "You're up to date!"])
                about.updaterDidNotFindUpdate(updater, error: error)
                precondition(texts().contains("Available: \(expected) (build 2)"))
                precondition(texts().contains("You're up to date!"))
            }
            panel.close()
            defaults.removePersistentDomain(forName: suite)
        } else if mode == "active" {
            let previous = updates.controller!
            previous.updater.setValue(true, forKey: "sessionInProgress")
            previous.updater.setValue(DeferredUpdate(), forKey: "resumableUpdate")
            preferences.receivesRCVersions = true
            precondition(updates.controller === previous, "An active check was interrupted")
            previous.updater.setValue(false, forKey: "sessionInProgress")
            // Drain the observation's queued replacement, using an event, not a delay.
            DispatchQueue.main.async {
                precondition(updates.controller !== previous)
                precondition(updates.controller.updater.value(forKey: "resumableUpdate") == nil)
                expectFeed(true)
                updates.controller.updater.setValue(true, forKey: "canCheckForUpdates")
                expectMenuEnabled(true)
                updates.controller.updater.setValue(false, forKey: "canCheckForUpdates")
                expectMenuEnabled(false)
                defaults.removePersistentDomain(forName: suite)
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
        } else if mode == "enable" {
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
            updater.automaticallyDownloadsUpdates = true
            updater.setValue(DeferredUpdate(), forKey: "resumableUpdate")
            preferences.receivesRCVersions = false
            precondition(updates.controller.updater.value(forKey: "resumableUpdate") == nil,
                         "Next check would resume a cached RC after disabling RC versions")
            precondition(updates.controller.updater.automaticallyDownloadsUpdates)
            precondition(!updates.controller.updater.automaticallyChecksForUpdates)
            expectFeed(false)
        } else {
            precondition(!preferences.receivesRCVersions, "Stable preference did not survive relaunch")
            expectFeed(false)
            defaults.removePersistentDomain(forName: suite)
        }
        print("Passed \(arch) \(mode)")
    }
}
