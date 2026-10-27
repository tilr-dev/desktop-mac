import Foundation

/// Ordering is shared by the real application and isolated filesystem fixtures.
struct AppUninstall {
    let bundle: URL
    let dataDirectories: [URL]
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    func run(removeServer: () async throws -> Void, stop: () async throws -> Void,
             cleanPreferences: () -> Void) async throws {
        try await removeServer()
        try await stop()
        for directory in dataDirectories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        cleanPreferences()
        try trash(bundle)
    }
}
