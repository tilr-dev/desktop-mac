import AppKit
import Yams

/// Settings, Sublime Text style. `default.yml` in the config folder (`dir`) holds every key with its default;
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
    var web: Web
    var nativePlugins: NativePlugins
    var sshAgent: SSHAgent
    var debug: Debug
    var localServer: LocalServer
    var watch: Watch
    var pluginManager: PluginManagerSettings

    enum CodingKeys: String, CodingKey {
        case site, apps, window, control, browser, web, debug, watch
        case pluginManager = "plugin_manager"
        case nativePlugins = "native_plugins"
        case sshAgent = "ssh_agent"
        case switching = "switch"
        case controlPlane = "control_plane"
        case localServer = "local_server"
    }

    struct App: Decodable {
        /// Window title, menu entry and the host of the app's origin (`tilr://<name>/`).
        var name: String
        var site: String
    }

    /// The bundled server, installed at launch for the default production instance only.
    struct LocalServer: Decodable {
        var enabled: Bool
        var port: UInt16
        var commandTimeout: Double
        var startupTimeout: Double
        var retryInterval: Double
        var updateChannel: String
        var autoCheck: Bool
        var checkInterval: Double
        var downloadTimeout: Double
        var maxFeedBytes: Int64
        var maxDownloadBytes: Int64
        enum CodingKeys: String, CodingKey {
            case enabled, port
            case commandTimeout = "command_timeout"
            case startupTimeout = "startup_timeout"
            case retryInterval = "retry_interval"
            case updateChannel = "update_channel"
            case autoCheck = "auto_check"
            case checkInterval = "check_interval"
            case downloadTimeout = "download_timeout"
            case maxFeedBytes = "max_feed_bytes"
            case maxDownloadBytes = "max_download_bytes"
        }
    }

    /// The window. `mode` applies at launch, the rest whenever the config changes.
    struct Windows: Decodable {
        var mode: Mode
        var dragHeight: CGFloat
        var resizeBorder: CGFloat
        var inset: Inset
        /// At launch: come to the front; false shows the window behind the active app.
        var activateAtLaunch: Bool
        var spaceMoveTimeout: Double
        var spaceMoveInterval: Double

        enum CodingKeys: String, CodingKey {
            case mode, inset
            case activateAtLaunch = "activate_at_launch"
            case spaceMoveTimeout = "space_move_timeout"
            case spaceMoveInterval = "space_move_interval"
            case dragHeight = "drag_height"
            case resizeBorder = "resize_border"
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
        /// When the apps that are not on screen load their page. At launch.
        var preload: Preload
    }

    /// `switch.preload`: `false` loads an app when it is first selected, `true` loads every app
    /// at launch, a number of seconds loads the rest that long after the first app's page finished.
    enum Preload: Decodable, Equatable {
        case onSelect
        case atLaunch
        case after(Double)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let all = try? c.decode(Bool.self) {
                self = all ? .atLaunch : .onSelect
                return
            }
            let seconds = try c.decode(Double.self)
            guard seconds.isFinite, seconds >= 0 else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "switch.preload: false, true or seconds >= 0")
            }
            self = .after(seconds)
        }
    }

    /// The plugin manager (PluginManagerHost.swift, the Rust library ../git/gitpm).
    /// Both keys apply on reload: the open workspace is closed, the next operation opens the new one.
    struct PluginManagerSettings: Decodable {
        /// The workspace folder (Config.resolve'd).
        var workspace: String
        /// Catalog location: HTTP(S) URL, local folder or JSON file; empty: none.
        var catalog: String
    }

    /// FSEvents for the apps' folders and config.yml (FolderWatcher.swift).
    struct Watch: Decodable {
        /// Seconds: changes within that window are reported together as one batch.
        var latency: Double
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
        /// Empty: no server. Config.resolve'd.
        var socket: String
        /// Console messages kept per app.
        var console: Int
        /// Seconds a command for an app whose page is not loaded yet waits for it to load.
        var loadTimeout: Double
        /// The page's console is caught at all (the relay script is installed). At launch.
        var consoleCapture: Bool
        /// Characters one caught console entry keeps; longer ones are cut and end in "…". At launch.
        var consoleEntryMax: Int

        enum CodingKeys: String, CodingKey {
            case socket, console
            case loadTimeout = "load_timeout"
            case consoleCapture = "console_capture"
            case consoleEntryMax = "console_entry_max"
        }
    }

    struct NativePlugins: Decodable {
        var directory: String
        var enabled: [String]
        var allowThirdParty: Bool
        var requestTimeout: Double
        var options: [String: PluginValue]
        enum CodingKeys: String, CodingKey {
            case directory, enabled, options
            case allowThirdParty = "allow_third_party"
            case requestTimeout = "request_timeout"
        }
    }

    /// Plugin-owned JSON configuration, extensible without changing the app schema.
    indirect enum PluginValue: Decodable {
        case null, bool(Bool), number(Double), string(String)
        case array([PluginValue]), object([String: PluginValue])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([PluginValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: PluginValue].self)) }
        }
        var value: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let v): return v
            case .number(let v): return v
            case .string(let v): return v
            case .array(let v): return v.map(\.value)
            case .object(let v): return v.mapValues(\.value)
            }
        }
    }

    /// The page's web views (WebViews.swift): a browser window of a plugin is a WKWebView of ours.
    struct Browser: Codable {
        /// The User-Agent the views send; empty for WebKit's own.
        var userAgent: String
        /// Bytes a tunnel reads from a connection at a time (Tunnel.swift).
        var tunnelChunk: Int
        /// Seconds before an agent's asynchronous JS operation times out.
        var automationTimeout: Double
        var automationPrivateInput: Bool
        var automationInputInterval: Double
        /// `all` | `main`: which frames get the browser automation script.
        var automationFrames: String
        /// Milliseconds between relayouts of an embedded page while its tile is being resized.
        var liveResizeInterval: Double
        /// Milliseconds between progress-only `tilr-webview` reports.
        var progressInterval: Double
        /// Seconds a browser view of a reloaded page waits to be adopted by the new page.
        var adoptGrace: Double
        /// Seconds a hidden browser view waits before its web content is released; 0: never.
        var discardAfter: Double

        enum CodingKeys: String, CodingKey {
            case userAgent = "user_agent"
            case tunnelChunk = "tunnel_chunk"
            case automationTimeout = "automation_timeout"
            case automationPrivateInput = "automation_private_input"
            case automationInputInterval = "automation_input_interval"
            case automationFrames = "automation_frames"
            case liveResizeInterval = "live_resize_interval"
            case progressInterval = "progress_interval"
            case adoptGrace = "adopt_grace"
            case discardAfter = "discard_after"
        }
    }

    /// How the page's web views render (Tab.swift; the browser plugin gets the same values).
    struct Web: Decodable {
        /// Pages may render at the display's native rate (120 Hz on ProMotion) instead of
        /// WebKit's 60 Hz cap (a guarded WebKit SPI, WebKitFeatures). At launch.
        var highRefreshRate: Bool

        enum CodingKeys: String, CodingKey {
            case highRefreshRate = "high_refresh_rate"
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

    /// Debug mode (Debug.swift): the page's performance collector and the process sampler.
    struct Debug: Decodable {
        /// The state at launch and after a config change that touches it; the palette and
        /// Tilr Control switch it at runtime.
        var enabled: Bool
        /// Where `record` writes its files (Config.resolve).
        var dir: String
        /// Seconds the collector (and the sampler) keep.
        var history: Double
        /// Seconds between process samples.
        var sample: Double
        /// Seconds `/usr/bin/footprint` may run for a Performance `footprint` request (Memory.swift).
        var footprintTimeout: Double
        /// Seconds `squeeze` waits after the low-memory notification before reading `after`.
        var squeezeSettle: Double
        /// The page's web view can be inspected (Safari → Develop → Tilr); also handed to the
        /// browser plugin as `browser.inspectable`. At launch.
        var inspectable: Bool

        enum CodingKeys: String, CodingKey {
            case enabled, dir, history, sample, inspectable
            case footprintTimeout = "footprint_timeout"
            case squeezeSettle = "squeeze_settle"
        }
    }

    /// `~/Library/Application Support/dev.tilr.mac`: the user's own instance.
    static let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.tilr.mac", isDirectory: true)

    /// The config folder: `--config DIR`, else `TILR_CONFIG`, else `~/Library/Application Support/dev.tilr.mac`. It holds
    /// config.yml, default.yml, the pid file and, by default, the control socket and debug
    /// records; another folder is another instance (Instance.swift: own storage, own title).
    static let dir: URL = {
        let args = CommandLine.arguments
        var given = args.firstIndex(of: "--config").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if given?.isEmpty ?? true { given = ProcessInfo.processInfo.environment["TILR_CONFIG"] }
        guard let given, !given.isEmpty else { return defaultDir }
        return URL(fileURLWithPath: (given as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }()

    /// Whether this is the user's own instance (`~/Library/Application Support/dev.tilr.mac`).
    static let isDefaultDir = dir.standardizedFileURL.path == defaultDir.standardizedFileURL.path

    /// `dir` as the defaults print it: under the home folder with `~`.
    static let shownDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = dir.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }()

    /// A path from the config: `~` expanded, a relative one resolved against the config folder.
    static func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : dir.appendingPathComponent(expanded).path
    }
    static let file = dir.appendingPathComponent("config.yml")
    static let defaultsFile = dir.appendingPathComponent("default.yml")

    /// Every setting with its default. Written to `default.yml` for reference; what config.yml
    /// does not override comes from here.
    static let defaultText = """
        # Tilr for Mac: every setting and its default. The app writes this file on each launch, so
        # edits here are lost. To change a setting, put the key into config.yml next to this file:
        # a map is merged key by key, a list or a value replaces the default whole.
        # Paths: ~ is the home folder; relative paths are resolved against the config folder
        # (this file's, \(shownDir): --config DIR or TILR_CONFIG, else ~/Library/Application Support/dev.tilr.mac).

        # The page: a folder with an index.html plus whatever it loads, served as tilr://default/.
        # Until there is one, the app shows a placeholder naming the folder. A change in the
        # folder hot-reloads the page. Ignored when apps: is not empty.
        site: apps/default

        # Several apps in the one window, each with its own folder and its own storage
        # (tilr://<name>/); switch: below moves between them.
        # apps:
        #   - name: Dashboard
        #     site: apps/default
        #   - name: Notes
        #     site: apps/notes
        apps: []

        # Bundled terminal server. These settings apply at launch, in the default
        # production instance only; --probe and separate --config instances never install it.
        local_server:
          # Also applies on reload. false stops Tilr's service, removes it from Login Items
          # and deletes the installed server (sessions, tokens and logs in server/state are
          # kept); true installs it again.
          enabled: true
          # Loopback port; 1..65535. Do not change while the managed service is loaded.
          port: 7890
          # Seconds allowed for each installation/check command.
          command_timeout: 15
          # Seconds to wait for the server to accept an authenticated connection.
          startup_timeout: 30
          # Seconds between startup checks.
          retry_interval: 0.25
          # Independent of the application's Sparkle channel: stable or beta.
          update_channel: stable
          # Check at launch and periodically. Installation requires the Update button.
          auto_check: true
          # Seconds between server update checks.
          check_interval: 86400
          # Seconds allowed for a server feed or binary download.
          download_timeout: 300
          # Maximum signed feed size and binary download size, in bytes.
          max_feed_bytes: 1048576
          max_download_bytes: 268435456

        window:
          # fullscreen covers the screen with the Dock and the menu bar hidden; window has a title
          # bar; frameless has none. The mode at launch; the Commands menu switches it later.
          mode: window
          # Frameless mode: a drag that starts within this many points from the top moves the window.
          drag_height: 32
          # Frameless mode: reserve this perimeter for resizing, in points; it does not drag.
          resize_border: 6
          # Initial desktop frame: the screen minus these margins, in points.
          # Later mode switches preserve the last desktop size and position.
          inset: { x: 200, y: 150 }
          # The app comes to the front when it starts; false shows the window behind the active app
          # without taking focus (the test instance of ./run.sh --test sets it). At launch.
          activate_at_launch: true
          # Seconds to wait for WindowServer to confirm a desktop move.
          space_move_timeout: 3
          # Seconds between desktop membership checks during a move.
          space_move_interval: 0.05

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
          # When the apps not on screen load their page (each loaded app is a WebContent process):
          #   false  an app loads when it is first selected;
          #   true   every app loads at launch;
          #   N      seconds after the first app's page has finished loading, the rest load in
          #          the background (an app selected earlier loads at once).
          # At launch; apps added later load when selected (true: at once).
          preload: 2

        # Watching the apps' folders (a change reloads the page) and config.yml (a save reloads
        # the config).
        watch:
          # Seconds: changes within that many seconds are reported together, so a save or a short
          # build makes one reload. Applies to folders watched after the change; config.yml at launch.
          latency: 0.2

        control_plane:
          # Opens the palette.
          hotkey: cmd+shift+p
          # Rows of the palette, top to bottom. action is one of:
          #   quit, fullscreen, window, frameless, always-on-top, reload, all-desktops, next-desktop,
          #   debug (switches debug: below at runtime; the row shows the title plus ": on" / ": off")
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
            - title: Debug recording
              action: debug

        # Tilr Control: a socket through which an agent, `tilr ctl` or `tilr mcp` drives the app:
        # lists and switches the apps, takes a snapshot of the page, reads its console, calls the
        # page's services (switches plugins, opens and moves windows). Only this user can open it;
        # whoever can is in charge of the pages. Empty: no server. Applies at launch.
        control:
          socket: \(shownDir)/control.sock
          # Console messages kept per app for the console command.
          console: 500
          # Seconds a command for an app whose page is not loaded yet (switch.preload) waits for
          # it to load before running anyway.
          load_timeout: 10
          # Catch the page's console for the console command (a script in every frame). At launch.
          console_capture: true
          # Characters one caught console entry keeps; a longer one is cut and ends in "…". At launch.
          console_entry_max: 4096

        # The plugin manager: installs plugins (Git repositories with a plugin.json and a ready
        # dist/ folder) into a workspace and keeps their versions. It runs the system git (and
        # curl for an HTTP catalog): without git (the Xcode Command Line Tools) an install fails
        # with an error that says so. Both keys apply on reload: the open workspace is closed and
        # the next operation opens the new one.
        plugin_manager:
          # The workspace folder: installed plugins, their repositories and state.json. ~ is the
          # home folder; a relative path is inside the config folder, so every instance has its own.
          workspace: plugins
          # Where plugins are browsed and installed from: an HTTP(S) URL, a local folder or a
          # catalog JSON file. Empty: no catalog (installs from a Git source only).
          catalog: https://pkg.tilr.dev

        # Independently compiled native plugins. User versions override bundled versions.
        # Directory and enabled set apply at launch; replacing loaded code needs a restart.
        native_plugins:
          allow_third_party: false # accept other publishers/ad-hoc native code with Tilr's process access; at launch
          directory: "native-plugins"
          enabled: [browser-webkit, audio]
          request_timeout: 30  # seconds before a native control request fails; at launch
          options: {}         # per-plugin JSON settings, keyed by plugin id; hot reloaded

        # How the apps' pages render.
        web:
          # true: pages render at the display's native rate (120 Hz on a ProMotion panel) instead
          # of WebKit's 60 Hz cap; costs up to 2× CPU/GPU while something animates. No effect on a
          # display whose rate is not a multiple of 60 (a 75 Hz one runs at its own rate anyway).
          # Uses a WebKit feature switch that is not public API; where it is missing the pages stay
          # at 60 Hz. Also applied to the browser plugin's web views (handed to it as
          # browser.high_refresh_rate, not a key of browser: below). At launch.
          high_refresh_rate: false

        # The page's web views: a plugin's browser window is a WKWebView of the app's, placed over
        # the window's content (the webviews service of the page). A key applies to views made
        # after the change unless its comment says otherwise.
        browser:
          # The User-Agent the views send. Empty: WebKit's own, which some sites take for an old
          # browser; Safari's own string makes them behave, e.g.
          # "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15".
          user_agent: ""
          # Seconds allowed for one browser automation JavaScript operation. Also the most a
          # discard waits for its media check, and how long a view coming back from a discard
          # keeps its picture when its page does not finish loading. On reload.
          automation_timeout: 10
          # Seconds between checks that native input focus reached the browser.
          automation_input_interval: 0.05
          # Allow guarded WebKit SPI for native hover; unavailable if disabled.
          automation_private_input: true
          # Which frames get the browser automation script: all, or main (iframes, often ads,
          # get none: less work per page, but automation cannot target an iframe).
          automation_frames: all
          # Milliseconds: how often an embedded page is relaid out while its tile is being
          # resized; the final size is always applied when the changes stop. Meanwhile the view
          # keeps its last size, clipped to the tile. 0: on every change. Moves apply at once.
          # Also the delay before a view that went hidden is pictured for discard_after (a float
          # dragged over it is not pictured on every cover). On reload.
          live_resize_interval: 40
          # Milliseconds between the views' load progress reports to the page that change only
          # the progress; the start, the end and every other change are reported at once. On
          # reload.
          progress_interval: 100
          # Seconds a browser view of a reloaded page (also a rebuild of the site) waits to be
          # adopted by the new page before it is disposed: the same window of the new page gets
          # the same view back, its content, scroll, forms and script state kept, nothing loaded
          # again. 0 disables adoption: every view goes with the page. Read at each navigation.
          adopt_grace: 10
          # Seconds a browser view stays hidden (not visible to the page, covered, or off-screen;
          # a parked view, a view in a concealed tab, or in a window that is occluded, minimized
          # or on another Space too) before its web content is released: its process exits and
          # its memory goes, its last picture stays in place, and history and scroll are restored
          # when it is shown again (the page loads again; script state, forms and media are
          # lost). A view playing media or using the camera or microphone is kept; the media
          # check waits up to automation_timeout, and the picture stays at most that long while
          # the view comes back. 0 never discards. On reload.
          discard_after: 0
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

        # Compatibility settings for the single web Performance collector.
        # The debug action opens Performance; ctl debug on/off changes its per-tab switch.
        debug:
          enabled: false  # seed collection on first navigation; web switch wins afterwards
          dir: \(shownDir)/debug  # default destination for ctl debug record JSON
          history: 60     # deprecated; shared web history is 120 seconds
          sample: 0.5     # deprecated; shared web sampler runs once per second
          footprint_timeout: 5  # seconds /usr/bin/footprint may run for Performance footprint / ctl debug footprint
          squeeze_settle: 2     # seconds squeeze (org.WebKit.lowMemory) waits before reading the footprint again
          # Safari → Develop → Tilr can inspect the page's web view; also applied to the browser
          # plugin's web views (handed to it as browser.inspectable, not a key of browser:). At launch.
          inspectable: true

        """

    /// The first config.yml: a pointer to the defaults and the one setting most people change.
    static let userText = """
        # Tilr for Mac. The app reloads this file on every save. Every setting and its default is in
        # default.yml next to this file; a key put here overrides it (a map key by key, a list or a
        # value whole).
        site: apps/default

        """

    /// The defaults alone, for before the config is read. They are part of the program, so a
    /// failure to parse them is a programming error.
    static let fallback: Config = try! YAMLDecoder().decode(Config.self, from: defaultNode)

    /// `defaultText` parsed once; `load()` merges config.yml over a copy of it.
    private static let defaultNode: Node = try! Yams.compose(yaml: defaultText)!

    /// Writes `default.yml` when its contents differ from the defaults, and `config.yml` when
    /// there is none yet. At launch and from Native Plugin Settings….
    static func writeDefaults() {
        let files = FileManager.default
        do {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: defaultsFile, encoding: .utf8)) != defaultText {
                try defaultText.write(to: defaultsFile, atomically: true, encoding: .utf8)
            }
            if !files.fileExists(atPath: file.path) {
                try userText.write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            print("config: cannot prepare folder \(dir.path): \(error)")
        }
    }

    /// The defaults with config.yml's overrides merged in.
    static func load() -> Config? {
        do {
            var merged = defaultNode
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
    case quit, fullscreen, window, frameless, reload, debug
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
