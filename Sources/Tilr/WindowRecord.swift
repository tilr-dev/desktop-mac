import AppKit

/// Durable host state. App URL origins and website storage are independent of host UUIDs.
struct WindowRecord: Codable {
    struct Frame: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        init(_ rect: NSRect) {
            x = rect.origin.x; y = rect.origin.y
            width = rect.width; height = rect.height
        }
        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
        var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    }
    var host: UUID
    var app: String
    var frame: Frame
    var screen: UInt32?
    var mode: Mode
    var space: UInt64?
    var allSpaces: Bool
    var onTop: Bool

    init(_ shell: Shell) {
        host = shell.hostID
        app = shell.current!.app.name
        frame = Frame(shell.savedFrame)
        screen = shell.window.screen.flatMap(Self.screenID)
        mode = shell.savedMode
        space = Spaces.of(shell.window).first
        allSpaces = shell.allSpaces
        onTop = shell.onTop
    }

    /// Project a desktop frame onto its saved screen, or a reachable fallback screen.
    func restoredFrame(displays: [(id: UInt32?, frame: NSRect)], fallback: NSRect?) -> NSRect {
        let target = screen.flatMap { identity in displays.first { $0.id == identity }?.frame }
            ?? fallback ?? displays.first?.frame
        var result = frame.rect
        if let target, target.intersection(result).width < 80 || target.intersection(result).height < 40 {
            result.origin = target.origin
            result.size.width = min(result.width, target.width)
            result.size.height = min(result.height, target.height)
        }
        return result
    }

    static func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

struct WindowWorkspace: Codable {
    var version = 1
    var key: UUID?
    var windows: [WindowRecord]

    static var url: URL { Config.dir.appendingPathComponent("windows.json") }

    static func read(from url: URL = url) -> WindowWorkspace? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard state.version == 1 else { return nil }
            return state
        } catch {
            print("windows: could not restore \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    func write(to url: URL = url) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch { print("windows: could not save \(url.path): \(error.localizedDescription)") }
    }
}
