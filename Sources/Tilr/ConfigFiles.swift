import Foundation

/// Direct UTF-8 files in the selected config directory, independent of the WebKit bridge.
struct ConfigFiles {
    let directory: URL

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func validate(_ name: String, writing: Bool = false) throws {
        guard !name.isEmpty, name != ".", !name.contains(".."),
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw Failure(message: "Config filename must be a single filename without paths or double dots.")
        }
        if writing && ["config.yml", "default.yml"].contains(name.lowercased()) {
            throw Failure(message: "Application settings file \(name) is read-only through the config bridge.")
        }
    }

    private func file(_ name: String, writing: Bool = false) throws -> URL {
        try Self.validate(name, writing: writing)
        let url = directory.appendingPathComponent(name)
        // Reject links rather than following them, including dangling links and aliases to settings.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw Failure(message: "Config file must be a regular file, not a directory or symbolic link.")
        }
        return url
    }

    func read(_ name: String) throws -> String? {
        let url = try file(name)
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    func write(_ name: String, text: String) throws {
        try text.write(to: file(name, writing: true), atomically: true, encoding: .utf8)
    }

    /// FSEvents can contain duplicate paths, nested paths, and the watched root itself.
    func changedNames(_ paths: [String]) -> [String] {
        let root = directory.resolvingSymlinksInPath().path
        return Set(paths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            // Resolve the existing parent so deleted files still match a symlinked root.
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == root else { return nil }
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return nil }
            return name
        }).sorted()
    }
}
