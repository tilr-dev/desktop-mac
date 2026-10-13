import WebKit

/// Guarded WebKit SPI: a copy of the app's WebKitFeatures (Tab.swift); a plugin cannot import the app.
/// `+[WKPreferences _features]` and `-_setEnabled:forFeature:`,
/// resolved at run time and never linked; listed in apps/mac/CLAUDE.md.
enum WebKitFeatures {
    /// On by default: rendering updates (rAF, CSS animations) near 60 Hz even on a 120 Hz panel.
    static let near60FPS = "PreferPageRenderingUpdatesNear60FPSEnabled"

    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    private typealias IsEnabled = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private static var reported = false

    /// Sets the feature `key` on `preferences` (before a web view is made with them). False when
    /// WebKit has no such feature or switch, or the switch did not take; that is logged once.
    @discardableResult
    static func set(_ key: String, enabled: Bool, on preferences: WKPreferences) -> Bool {
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        let list = NSSelectorFromString("_features")
        let features = (WKPreferences.self as AnyObject).responds(to: list)
            ? (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject] : nil
        let feature = features?.first { $0.responds(to: NSSelectorFromString("key")) && $0.value(forKey: "key") as? String == key }
        guard let feature, preferences.responds(to: setter) else {
            return unavailable(key, "no _features entry or _setEnabled:forFeature:")
        }
        unsafeBitCast(preferences.method(for: setter), to: SetEnabled.self)(preferences, setter, enabled, feature)
        // Read back where WebKit can say: a switch that did not take is no success.
        let getter = NSSelectorFromString("_isEnabledForFeature:")
        guard preferences.responds(to: getter) else { return true }
        guard unsafeBitCast(preferences.method(for: getter), to: IsEnabled.self)(preferences, getter, feature) == enabled else {
            return unavailable(key, "the switch did not take")
        }
        return true
    }

    private static func unavailable(_ key: String, _ why: String) -> Bool {
        if !reported {
            reported = true
            print("WebKit feature \(key): unavailable (\(why))")
        }
        return false
    }
}
