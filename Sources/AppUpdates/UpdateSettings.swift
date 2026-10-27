import AppKit
import Sparkle

/// Kept alive by AppUpdates so the preference controls retain their targets.
final class UpdateSettings: NSObject {
    private let preferences: UpdatePreferences
    private let updater: SPUUpdater
    private var panel: NSPanel?
    private let rc = NSButton(checkboxWithTitle: "Receive RC versions", target: nil, action: nil)
    private let checks = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let downloads = NSButton(checkboxWithTitle: "Automatically download updates", target: nil, action: nil)

    init(preferences: UpdatePreferences, updater: SPUUpdater) {
        self.preferences = preferences
        self.updater = updater
        super.init()
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Update Settings"
            panel.isReleasedWhenClosed = false
            rc.target = self
            rc.action = #selector(changeRC(_:))
            checks.bind(.value, to: updater, withKeyPath: "automaticallyChecksForUpdates", options: nil)
            downloads.bind(.value, to: updater, withKeyPath: "automaticallyDownloadsUpdates", options: nil)
            downloads.bind(.enabled, to: updater, withKeyPath: "allowsAutomaticUpdates", options: nil)
            let hint = NSTextField(wrappingLabelWithString: "RC versions are release candidates. Changes apply to the next update check.")
            hint.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [checks, downloads, rc, hint])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = panel.contentView!
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            ])
            panel.center()
            self.panel = panel
        }
        rc.state = preferences.receivesRCVersions ? .on : .off
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc private func changeRC(_ sender: NSButton) {
        preferences.receivesRCVersions = sender.state == .on
    }
}
