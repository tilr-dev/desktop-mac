import AppKit
import Sparkle

/// A native About panel. Sparkle supplies the server version using the same feed and
/// compatibility rules as installation; opening the panel only requests information.
final class About: NSObject, SPUUpdaterDelegate {
    private var panel: NSPanel?
    private let available = NSTextField(wrappingLabelWithString: "Not checked")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let plugins = NSTextField(wrappingLabelWithString: "")
    private var contentStack: NSStackView?
    private var checking = false

    func show(updater: SPUStandardUpdaterController?, pluginStatus: [String]) {
        plugins.stringValue = (["Native plugins"] + (pluginStatus.isEmpty ? ["None loaded"] : pluginStatus)).joined(separator: "\n")
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "About Tilr"
            panel.isReleasedWhenClosed = false
            let icon = NSImageView(image: NSApp.applicationIconImage)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 80), icon.heightAnchor.constraint(equalToConstant: 80)])
            let name = NSTextField(labelWithString: "Tilr")
            name.font = .boldSystemFont(ofSize: 22)
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
            let installed = NSTextField(labelWithString: "Installed: \(version) (build \(build))")
            available.alignment = .center
            status.alignment = .center
            status.maximumNumberOfLines = 3
            status.textColor = .secondaryLabelColor
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let check = NSButton(title: "Check for Updates…", target: updater,
                                 action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
            check.bezelStyle = .rounded
            if let updater {
                check.bind(.enabled, to: updater.updater, withKeyPath: "canCheckForUpdates", options: nil)
            } else {
                check.isEnabled = false
                available.stringValue = "Available: Not configured"
                status.stringValue = "This build has no active update service."
            }
            plugins.isSelectable = true
            plugins.alignment = .center
            let stack = NSStackView(views: [icon, name, installed, available, status, check, plugins])
            contentStack = stack
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = panel.contentView!
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                available.widthAnchor.constraint(equalTo: stack.widthAnchor),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor),
                plugins.widthAnchor.constraint(equalTo: stack.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            ])
            panel.center()
            self.panel = panel
        }
        if let panel, let contentStack {
            panel.contentView?.layoutSubtreeIfNeeded()
            // Recompute on every opening: sessions and loaded versions may have changed.
            let inset = panel.contentView!.frame.height - contentStack.frame.maxY
            panel.setContentSize(NSSize(width: panel.contentView!.frame.width,
                                        height: contentStack.fittingSize.height + inset * 2))
        }
        panel?.makeKeyAndOrderFront(nil)
        if let updater, updater.updater.canCheckForUpdates {
            checking = true
            available.stringValue = "Available: Checking…"
            status.stringValue = ""
            updater.updater.checkForUpdateInformation()
        } else if updater != nil, !checking {
            status.stringValue = "An update check is already in progress."
        }
    }

    private func found(_ item: SUAppcastItem) {
        available.stringValue = "Available: \(item.displayVersionString) (build \(item.versionString))"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found(item)
        status.stringValue = "An update is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        if let item = (error as NSError).userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem {
            found(item)
        } else {
            available.stringValue = "Available: No release found"
        }
        status.stringValue = error.localizedDescription
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        checking = false
        if let error, (error as NSError).code != SUError.noUpdateError.rawValue {
            available.stringValue = "Available: Could not check"
            status.stringValue = error.localizedDescription
        }
    }
}
