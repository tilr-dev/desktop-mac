import CryptoKit
import Foundation
import WebKit

/// This instance of the app, named by its config folder (`Config.dir`). The user's own one is
/// `~/Library/Application Support/dev.tilr.mac`; any other folder (`--config DIR`, `TILR_CONFIG`; `./run.sh --test` uses
/// `~/Library/Application Support/dev.tilr.mac.test`) is a separate instance that runs beside it:
/// - its own web storage: the pages' data store is `WKWebsiteDataStore(forIdentifier:)` with a
///   UUID kept in `<dir>/storage-id` (the user's instance keeps the default store and its data),
///   and every web view profile's store id is mixed with that UUID, so a profile id the two
///   pages share still names two stores;
/// - its own window title, `<title> · <folder name>`;
/// - `<dir>/tilr.pid`, the running process, so `run.sh` stops exactly this instance.
enum Instance {
    static let pidFile = Config.dir.appendingPathComponent("tilr.pid")
    static let storageFile = Config.dir.appendingPathComponent("storage-id")

    /// nil for the user's instance; else the UUID in `storage-id`, made on the first launch.
    static let storageID: UUID? = {
        guard !Config.isDefaultDir else { return nil }
        let text = (try? String(contentsOf: storageFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, let id = UUID(uuidString: text) { return id }
        let id = UUID()
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        do {
            try (id.uuidString + "\n").write(to: storageFile, atomically: true, encoding: .utf8)
        } catch {
            print("instance: \(storageFile.path): \(error); storage kept for this run only")
        }
        return id
    }()

    /// The pages' data store (localStorage, IndexedDB, cookies of the tabs); one object for all tabs.
    static let store: WKWebsiteDataStore = storageID.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()

    /// The store id of a web view profile: the profile's own in the user's instance, else one
    /// derived from it and `storageID` (stable across launches).
    static func profileStore(_ profile: UUID) -> UUID {
        guard let storageID else { return profile }
        var bytes = Array(SHA256.hash(data: Data((storageID.uuidString + "/" + profile.uuidString).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The folder's name after a window title, for an instance that is not the user's.
    static func title(_ base: String) -> String {
        Config.isDefaultDir ? base : "\(base) · \(Config.dir.lastPathComponent)"
    }

    /// At launch: writes the pid file and says which instance this is.
    static func launched() {
        try? "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
        if !Config.isDefaultDir {
            print("instance: \(Config.dir.path), storage \(storageID?.uuidString ?? "default")")
        }
    }

    /// At quit: removes the pid file when it is still this process's.
    static func terminating() {
        let text = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == String(getpid()) { try? FileManager.default.removeItem(at: pidFile) }
    }
}
