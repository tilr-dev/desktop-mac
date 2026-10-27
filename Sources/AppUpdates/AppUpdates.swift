import AppKit
import Sparkle
import UserNotifications

/// Retain one instance for the application's lifetime. Sparkle owns download,
/// signature verification, installation and relaunch; this module owns reminders.
/// The host must forward notification callbacks here if it supplies its own delegate.
public final class AppUpdates: NSObject, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    @objc public dynamic private(set) var controller: SPUStandardUpdaterController!
    private let center = UNUserNotificationCenter.current()
    private let identifier = "app-update-available"
    private var notificationsAllowed = false
    private var pendingVersion: String?
    private var started = false
    public let preferences: UpdatePreferences
    private let feedDelegate: UpdateFeedDelegate
    private var settings: UpdateSettings?
    private var sessionObserver: NSKeyValueObservation?
    private var currentFeed: String

    public init(updaterDelegate: SPUUpdaterDelegate? = nil, preferences: UpdatePreferences = UpdatePreferences()) {
        self.preferences = preferences
        currentFeed = preferences.feedURL
        feedDelegate = UpdateFeedDelegate(preferences: preferences, host: updaterDelegate)
        super.init()
        makeController()
        preferences.didChange = { [weak self] in self?.refreshFeed() }
    }

    private func makeController() {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: feedDelegate, userDriverDelegate: self)
        sessionObserver = controller.updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            // Sparkle completes its callback and schedules its old timer before retiring it.
            DispatchQueue.main.async { self?.refreshFeed() }
        }
    }

    private func refreshFeed() {
        guard preferences.feedURL != currentFeed, !controller.updater.sessionInProgress else { return }
        // Sparkle can retain a deferred update after a session ends. A new updater
        // discards that in-memory offer; deinitializing the old one cancels its timer.
        currentFeed = preferences.feedURL
        makeController()
        settings?.use(updater: controller.updater)
        if started { controller.startUpdater() }
    }

    @objc public func checkForUpdates(_ sender: Any?) {
        refreshFeed()
        controller.checkForUpdates(sender)
    }

    public func checkForUpdateInformation() {
        refreshFeed()
        controller.updater.checkForUpdateInformation()
    }

    public func showSettings() {
        if settings == nil { settings = UpdateSettings(preferences: preferences, updater: controller.updater) }
        settings?.show()
    }

    public func start() {
        guard !started else { return }
        started = true
        if center.delegate == nil { center.delegate = self }
        center.requestAuthorization(options: [.alert]) { [weak self] _, _ in
            self?.refreshAuthorization()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAuthorization),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        controller.startUpdater()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationsAllowed = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
            }
        }
    }

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                     andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Without notification permission, retain Sparkle's normal UI.
        !notificationsAllowed
    }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                          forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        pendingVersion = update.versionString
        NSApp.dockTile.badgeLabel = "↑"
        let content = UNMutableNotificationContent()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
        content.title = "\(name) Update Available"
        content.body = "Version \(update.displayVersionString) is available. Click to review and install."
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, self.pendingVersion == update.versionString else { return }
                self.controller.checkForUpdates(nil)
            }
        }
    }

    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { clearReminder() }
    public func standardUserDriverWillFinishUpdateSession() { clearReminder() }

    private func clearReminder() {
        pendingVersion = nil
        NSApp.dockTile.badgeLabel = nil
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier == identifier ? [.banner, .list] : [])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.identifier == identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.controller.checkForUpdates(nil)
            completionHandler()
        }
    }
}
