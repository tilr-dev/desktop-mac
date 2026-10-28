import Foundation
import Sparkle

/// A separate preference from Sparkle's automatic checks and downloads.
public final class UpdatePreferences {
    private let defaults: UserDefaults
    private let architecture: String
    var didChange: (() -> Void)?
    private static let rcKey = "TilrReceiveRCVersions"

    public static var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        #error("Unsupported update architecture")
        #endif
    }

    public init(defaults: UserDefaults = .standard, architecture: String = UpdatePreferences.nativeArchitecture) {
        precondition(["arm64", "x86_64"].contains(architecture))
        self.defaults = defaults
        self.architecture = architecture
    }

    public var receivesRCVersions: Bool {
        get { defaults.bool(forKey: Self.rcKey) }
        set {
            guard newValue != receivesRCVersions else { return }
            defaults.set(newValue, forKey: Self.rcKey)
            didChange?()
        }
    }

    public var daemonChannel: String { receivesRCVersions ? "beta" : "stable" }

    public var feedURL: String {
        let channel = receivesRCVersions ? "beta/" : ""
        return "https://cdn.tilr.dev/mac/\(channel)\(architecture)/appcast.xml"
    }
}

/// Own feed routing while preserving optional callbacks from the host (About).
final class UpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    let preferences: UpdatePreferences
    private weak var host: SPUUpdaterDelegate?

    init(preferences: UpdatePreferences, host: SPUUpdaterDelegate?) {
        self.preferences = preferences
        self.host = host
        super.init()
    }

    func feedURLString(for updater: SPUUpdater) -> String? { preferences.feedURL }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (host?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let host, host.responds(to: selector) { return host }
        return super.forwardingTarget(for: selector)
    }
}
