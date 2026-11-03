import Foundation

@main struct ConfigFilesTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ConfigFiles(directory: root)
        func rejects(_ action: () throws -> Void) {
            do { try action(); fail("Expected config file rejection") }
            catch { expect(!error.localizedDescription.isEmpty) }
        }
        for name in ["", ".", "..", "../x", "x/y", "x\\y", "x..y", "x\0y"] {
            rejects { try ConfigFiles.validate(name) }
        }
        for name in ["keys.yml", "default-keys.yml", "test.yml", "日本語.yml"] {
            try ConfigFiles.validate(name, writing: true)
        }
        for name in ["config.yml", "default.yml", "CONFIG.YML", "Default.yml"] {
            try ConfigFiles.validate(name)
            rejects { try files.write(name, text: "forbidden") }
            expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        let missing = try files.read("missing.yml"); expect(missing == nil)
        try files.write("test.yml", text: "a: 1")
        let first = try files.read("test.yml"); expect(first == "a: 1")
        try files.write("test.yml", text: "Unicode: 日本語\n")
        let second = try files.read("test.yml"); expect(second == "Unicode: 日本語\n")
        try "settings".write(to: root.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
        let settings = try files.read("config.yml"); expect(settings == "settings")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        rejects { _ = try files.read("nested") }
        rejects { try files.write("nested", text: "no") }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.yml").path,
                                                  withDestinationPath: root.appendingPathComponent("config.yml").path)
        rejects { _ = try files.read("link.yml") }
        rejects { try files.write("link.yml", text: "no") }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling.yml").path,
                                                  withDestinationPath: root.appendingPathComponent("missing.yml").path)
        rejects { _ = try files.read("dangling.yml") }
        rejects { try files.write("dangling.yml", text: "no") }
        let names = files.changedNames([root.path, root.appendingPathComponent("test.yml").path,
                                       root.appendingPathComponent("test.yml").path,
                                       root.appendingPathComponent("deleted.yml").path,
                                       root.appendingPathComponent("unreadable..yml").path,
                                       nested.path, nested.appendingPathComponent("child.yml").path])
        expect(names == ["deleted.yml", "test.yml", "unreadable..yml"])
        let linkedRoot = root.appendingPathComponent("config-link")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        let linkedFiles = ConfigFiles(directory: linkedRoot)
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedPaths = [resolvedRoot.appendingPathComponent("config.yml").path,
                             resolvedRoot.appendingPathComponent("test.yml").path,
                             resolvedRoot.appendingPathComponent("deleted.yml").path,
                             resolvedRoot.path, nested.resolvingSymlinksInPath().path,
                             nested.appendingPathComponent("child.yml").resolvingSymlinksInPath().path]
        expect(linkedFiles.changedNames(resolvedPaths) == ["config.yml", "deleted.yml", "test.yml"],
               "Resolved watcher paths must match a symlinked config directory")
        expect(files.changedNames([linkedRoot.appendingPathComponent("config.yml").path,
                                   linkedRoot.appendingPathComponent("deleted.yml").path]) == ["config.yml", "deleted.yml"],
               "Symlinked watcher paths must match the real config directory, including deleted files")
        print("config file validation and IO tests passed")
    }
}
