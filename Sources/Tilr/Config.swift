import AppKit
import Yams

/// `~/.config/tilr/config.yml`. Written with the defaults below when missing, read again on
/// every change. A broken file keeps the last good config and says why on stdout.
struct Config: Decodable {
    /// Folder with the page (`index.html`); `~` is expanded. Missing: `~/tilr`. Ignored when `apps` is set.
    var site: String?
    /// Several windows, one per app; each shows its own folder. Replaces `site`.
    var apps: [App]?
    var controlPlane: ControlPlane

    enum CodingKeys: String, CodingKey {
        case site, apps
        case controlPlane = "control_plane"
    }

    struct App: Decodable {
        /// Window title, menu entry and the host of the app's origin (`tilr://<name>/`).
        var name: String
        var site: String
    }

    /// The command palette: `hotkey` opens it, `commands` are its rows, top to bottom.
    struct ControlPlane: Decodable {
        var hotkey: Shortcut?
        var commands: [Command]
    }

    struct Command: Decodable {
        var title: String
        var action: Action
        /// Optional shortcut that runs the command without opening the palette.
        var key: Shortcut?
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/tilr", isDirectory: true)
    static let file = dir.appendingPathComponent("config.yml")

    static let defaultText = """
        # Tilr for Mac. The app reloads this file on every save.
        # Folder with the page: an index.html plus whatever it loads. Until there is one, the app
        # shows a placeholder naming the folder. A change in the folder hot-reloads the page.
        site: ~/tilr
        # Or several windows, each with its own folder and its own storage. Replaces site: when set.
        # ctrl+alt+← / ctrl+alt+→ cycle through them, ctrl+alt+1..9 jump to one.
        # apps:
        #   - name: Dashboard
        #     site: ~/tilr
        #   - name: Notes
        #     site: ~/tilr-notes
        control_plane:
          # Opens the palette. Modifiers: cmd, shift, alt (opt), ctrl.
          hotkey: cmd+shift+p
          # Rows of the palette, top to bottom. action is one of:
          #   quit, fullscreen, window, frameless, always-on-top, reload, all-desktops, next-desktop
          # key is optional: a shortcut that runs the command directly.
          commands:
            - title: Exit
              action: quit
              key: cmd+q
            - title: Full Screen
              action: fullscreen
              key: cmd+1
            - title: Window
              action: window
              key: cmd+2
            - title: Window without Title Bar
              action: frameless
              key: cmd+3
            - title: Always on Top
              action: always-on-top
              key: cmd+shift+t

        """

    static func load() -> Config? {
        let files = FileManager.default
        if !files.fileExists(atPath: file.path) {
            try? files.createDirectory(at: dir, withIntermediateDirectories: true)
            try? defaultText.write(to: file, atomically: true, encoding: .utf8)
        }
        do {
            return try YAMLDecoder().decode(Config.self, from: String(contentsOf: file, encoding: .utf8))
        } catch {
            print("config: \(file.path): \(error)")
            return nil
        }
    }
}

enum Action: String, Decodable {
    case quit, fullscreen, window, frameless, reload
    case alwaysOnTop = "always-on-top"
    case allDesktops = "all-desktops"
    case nextDesktop = "next-desktop"
}

/// `cmd+shift+p` → key "p" with ⌘⇧.
struct Shortcut: Decodable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        var parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.popLast(), !key.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty shortcut"))
        }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "unknown modifier \"\(part)\" in \"\(text)\""))
            }
        }
        self.key = key
        self.modifiers = modifiers
    }
}
