import AppKit
import Yams

/// Settings, Sublime Text style. `~/.config/tilr/default.yml` holds every key with its default;
/// the app writes it on each launch. `config.yml` next to it holds the user's overrides and is
/// read again on every save: a map there is merged key by key, a list or a value replaces the
/// default whole. A broken config.yml keeps the last good config and says why on stdout.
struct Config: Decodable {
    var site: String
    var apps: [App]
    var window: Windows
    var switching: Switching
    var controlPlane: ControlPlane
    var control: Control
    var browser: Browser
    var sshAgent: SSHAgent

    enum CodingKeys: String, CodingKey {
        case site, apps, window, control, browser
        case sshAgent = "ssh_agent"
        case switching = "switch"
        case controlPlane = "control_plane"
    }

    struct App: Decodable {
        /// Window title, menu entry and the host of the app's origin (`tilr://<name>/`).
        var name: String
        var site: String
    }

    /// The window. `mode` applies at launch, the rest whenever the config changes.
    struct Windows: Decodable {
        var mode: Mode
        var dragHeight: CGFloat
        var inset: Inset

        enum CodingKeys: String, CodingKey {
            case mode, inset
            case dragHeight = "drag_height"
        }

        struct Inset: Decodable {
            var x: CGFloat
            var y: CGFloat
        }
    }

    /// Switching between the apps (the window's tabs).
    struct Switching: Decodable {
        var duration: Double
        var easing: Easing
        var next: Shortcut
        var previous: Shortcut
        /// Modifiers only; with 1..9 they jump to the window at that place in `apps`.
        var jump: Shortcut
    }

    enum Easing: String, Decodable {
        case easeInOut = "ease-in-out"
        case easeIn = "ease-in"
        case easeOut = "ease-out"
        case linear

        var function: CAMediaTimingFunction {
            switch self {
            case .easeInOut: CAMediaTimingFunction(name: .easeInEaseOut)
            case .easeIn: CAMediaTimingFunction(name: .easeIn)
            case .easeOut: CAMediaTimingFunction(name: .easeOut)
            case .linear: CAMediaTimingFunction(name: .linear)
            }
        }
    }

    /// The command palette: `hotkey` opens it, `commands` are its rows, top to bottom.
    struct ControlPlane: Decodable {
        var hotkey: Shortcut
        var commands: [Command]
    }

    struct Command: Decodable {
        var title: String
        var action: Action
        /// Optional shortcut that runs the command without opening the palette.
        var key: Shortcut?
    }

    /// Tilr Control (Control.swift): the socket an agent drives the app through. At launch.
    struct Control: Decodable {
        /// Empty: no server.
        var socket: String
        /// Console messages kept per app.
        var console: Int
    }

    /// The page's web views (WebViews.swift): a browser window of a plugin is a WKWebView of ours.
    struct Browser: Decodable {
        /// The User-Agent the views send; empty for WebKit's own.
        var userAgent: String
        /// Bytes a tunnel reads from a connection at a time (Tunnel.swift).
        var tunnelChunk: Int

        enum CodingKeys: String, CodingKey {
            case userAgent = "user_agent"
            case tunnelChunk = "tunnel_chunk"
        }
    }

    /// The user's SSH agent for the page (Agent.swift), forwarded to a tilr server's panes.
    struct SSHAgent: Decodable {
        /// The agent's socket; empty: found automatically (AgentHost.resolve).
        var socket: String
        /// Connections to the agent one page may have open.
        var maxStreams: Int
        /// Bytes read from the agent at a time, the most one `data` event carries.
        var chunk: Int

        enum CodingKeys: String, CodingKey {
            case socket, chunk
            case maxStreams = "max_streams"
        }
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/tilr", isDirectory: true)
    static let file = dir.appendingPathComponent("config.yml")
    static let defaultsFile = dir.appendingPathComponent("default.yml")

    /// Every setting with its default. Written to `default.yml` for reference; what config.yml
    /// does not override comes from here.
    static let defaultText = """
        # Tilr for Mac: every setting and its default. The app writes this file on each launch, so
        # edits here are lost. To change a setting, put the key into config.yml next to this file:
        # a map is merged key by key, a list or a value replaces the default whole.

        # The page: a folder with an index.html plus whatever it loads, served as tilr://app/.
        # Until there is one, the app shows a placeholder naming the folder. A change in the
        # folder hot-reloads the page. Ignored when apps: is not empty.
        site: ~/tilr

        # Several apps in the one window, each with its own folder and its own storage
        # (tilr://<name>/); switch: below moves between them.
        # apps:
        #   - name: Dashboard
        #     site: ~/tilr
        #   - name: Notes
        #     site: ~/tilr-notes
        apps: []

        window:
          # fullscreen covers the screen with the Dock and the menu bar hidden; window has a title
          # bar; frameless has none. The mode at launch; the Commands menu switches it later.
          mode: fullscreen
          # Frameless mode: a drag that starts within this many points from the top moves the window.
          drag_height: 32
          # Window and frameless modes: the window is the screen minus these margins, in points.
          inset: { x: 200, y: 150 }

        # Switching between the apps: the new page slides into the window, the old one slides out.
        switch:
          # Seconds; 0 switches without an animation.
          duration: 0.3
          # ease-in-out, ease-in, ease-out or linear.
          easing: ease-in-out
          # Modifiers: cmd, shift, alt (opt), ctrl. Keys: a letter, a digit, left, right, up, down.
          next: ctrl+alt+right
          previous: ctrl+alt+left
          # Modifiers only: with 1..9 they jump to the app at that place in apps.
          jump: ctrl+alt

        control_plane:
          # Opens the palette.
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

        # Tilr Control: a socket through which an agent, `tilr ctl` or `tilr mcp` drives the app:
        # lists and switches the apps, takes a snapshot of the page, reads its console, calls the
        # page's services (switches plugins, opens and moves windows). Only this user can open it;
        # whoever can is in charge of the pages. Empty: no server. Applies at launch.
        control:
          socket: ~/.config/tilr/control.sock
          # Console messages kept per app for the console command.
          console: 500

        # The page's web views: a plugin's browser window is a WKWebView of the app's, placed over
        # the window's content (the webviews service of the page). Applies to views made after
        # the change.
        browser:
          # The User-Agent the views send. Empty: WebKit's own, which some sites take for an old
          # browser; Safari's own string makes them behave, e.g.
          # "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15".
          user_agent: ""
          # A profile's tunnel (a tilr server's /socks, bridged to a local SOCKS port for WebKit):
          # bytes read from a connection at a time, the most one WebSocket message carries; the
          # next read waits until they are sent. Applies to tunnels started after the change.
          tunnel_chunk: 65536

        # The user's SSH agent, for the page to forward to a tilr server's panes (like ssh -A).
        # The agent is exposed to whatever the page forwards it to; an agent that asks per
        # signature (1Password, when set up so) still asks.
        ssh_agent:
          # The agent's socket, ~ expanded. Empty: the first of these that exists:
          # SSH_AUTH_SOCK of the app's environment, IdentityAgent in ~/.ssh/config (the first
          # one for all hosts), 1Password's agent
          # (~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock), then
          # `launchctl getenv SSH_AUTH_SOCK` (the system's agent). An app started from Finder
          # does not get the shell's environment, hence the list. Applies to connections opened
          # after the change.
          socket: ""
          # Connections to the agent one page may have open at a time; an open over it fails.
          max_streams: 64
          # Bytes read from the agent at a time, the most one event to the page carries.
          chunk: 65536

        """

    /// The first config.yml: a pointer to the defaults and the one setting most people change.
    static let userText = """
        # Tilr for Mac. The app reloads this file on every save. Every setting and its default is in
        # default.yml next to this file; a key put here overrides it (a map key by key, a list or a
        # value whole).
        site: ~/tilr

        """

    /// The defaults alone, for before the config is read. They are part of the program, so a
    /// failure to parse them is a programming error.
    static let fallback: Config = try! YAMLDecoder().decode(Config.self, from: defaultText)

    /// Writes `default.yml`, and `config.yml` when there is none yet. Once, at launch.
    static func writeDefaults() {
        let files = FileManager.default
        try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaultText.write(to: defaultsFile, atomically: true, encoding: .utf8)
        if !files.fileExists(atPath: file.path) {
            try? userText.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The defaults with config.yml's overrides merged in.
    static func load() -> Config? {
        do {
            var merged = try Yams.compose(yaml: defaultText)!
            // A missing or empty (comments only) file overrides nothing.
            let userText = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if let overrides = try Yams.compose(yaml: userText) {
                merged = merge(merged, overrides)
            }
            return try YAMLDecoder().decode(Config.self, from: merged)
        } catch {
            print("config: \(file.path): \(error)")
            return nil
        }
    }

    /// Maps merge key by key, anything else is replaced by `over`.
    private static func merge(_ base: Node, _ over: Node) -> Node {
        guard case .mapping(var result) = base, case .mapping(let overrides) = over else { return over }
        for pair in overrides {
            result[pair.key] = result[pair.key].map { merge($0, pair.value) } ?? pair.value
        }
        return .mapping(result)
    }
}

enum Action: String, Decodable {
    case quit, fullscreen, window, frameless, reload
    case alwaysOnTop = "always-on-top"
    case allDesktops = "all-desktops"
    case nextDesktop = "next-desktop"
}

/// `cmd+shift+p` → key "p" with ⌘⇧. Arrows and a few other keys by name; `ctrl+alt` alone is
/// modifiers without a key (`switch.jump`).
struct Shortcut: Decodable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    /// Function and control keys, as NSMenuItem.keyEquivalent wants them.
    static let named: [String: String] = [
        "left": "\u{F702}", "right": "\u{F703}", "up": "\u{F700}", "down": "\u{F701}",
        "enter": "\r", "return": "\r", "tab": "\t", "space": " ", "esc": "\u{1B}", "escape": "\u{1B}",
        "delete": "\u{7F}", "backspace": "\u{7F}",
    ]

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        func fail(_ why: String) -> DecodingError {
            DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(why) in \"\(text)\""))
        }
        var key = ""
        var modifiers: NSEvent.ModifierFlags = []
        for (i, part) in parts.enumerated() {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default:
                guard i == parts.count - 1 else { throw fail("unknown modifier \"\(part)\"") }
                key = Self.named[part] ?? part
                guard key.count == 1 else { throw fail("unknown key \"\(part)\"") }
            }
        }
        guard !key.isEmpty || !modifiers.isEmpty else { throw fail("empty shortcut") }
        self.key = key
        self.modifiers = modifiers
    }
}
