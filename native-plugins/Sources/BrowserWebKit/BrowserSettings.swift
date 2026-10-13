import Foundation

struct BrowserSettings: Decodable {
    /// The User-Agent the views send; empty for WebKit's own.
    var userAgent: String
    /// Bytes a tunnel reads from a connection at a time (Tunnel.swift).
    var tunnelChunk: Int
    /// Seconds before an agent's asynchronous JS operation times out.
    var automationTimeout: Double
    var automationPrivateInput: Bool
    var automationInputInterval: Double
    /// Which frames get the automation script: `all`, or `main` (no iframes; frame-targeted
    /// automation then sees the main frame only).
    var automationFrames: String = "all"
    /// Milliseconds between relayouts of an embedded page while its rect keeps changing size
    /// (ViewSurface.resizeInterval); the final size is always applied.
    var liveResizeInterval: Double = 40
    /// Milliseconds between `tilr-webview` reports that differ only in `progress`.
    var progressInterval: Double = 100
    /// Seconds a view with a `key` of a page that navigated (a reload) waits to be adopted by
    /// the new page before it goes; 0: no adoption, every view goes with the page.
    var adoptGrace: Double = 10
    /// Seconds a view stays hidden (not visible to the page, covered, off-screen, parked)
    /// before its web content is released (WebViews.swift, discarding); 0: never.
    var discardAfter: Double = 0
    /// Host keys (not of the config's `browser:`): Safari → Develop can inspect the views
    /// (`debug.inspectable`), and they render at the display's rate (`web.high_refresh_rate`).
    var inspectable: Bool = true
    var highRefreshRate: Bool = false

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
        case inspectable
        case highRefreshRate = "high_refresh_rate"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userAgent = try c.decode(String.self, forKey: .userAgent)
        tunnelChunk = try c.decode(Int.self, forKey: .tunnelChunk)
        automationTimeout = try c.decode(Double.self, forKey: .automationTimeout)
        automationPrivateInput = try c.decode(Bool.self, forKey: .automationPrivateInput)
        automationInputInterval = try c.decode(Double.self, forKey: .automationInputInterval)
        // Keys a host older than them does not send: the same defaults as the host's.
        automationFrames = try c.decodeIfPresent(String.self, forKey: .automationFrames) ?? automationFrames
        liveResizeInterval = try c.decodeIfPresent(Double.self, forKey: .liveResizeInterval) ?? liveResizeInterval
        progressInterval = try c.decodeIfPresent(Double.self, forKey: .progressInterval) ?? progressInterval
        adoptGrace = try c.decodeIfPresent(Double.self, forKey: .adoptGrace) ?? adoptGrace
        discardAfter = try c.decodeIfPresent(Double.self, forKey: .discardAfter) ?? discardAfter
        inspectable = try c.decodeIfPresent(Bool.self, forKey: .inspectable) ?? inspectable
        highRefreshRate = try c.decodeIfPresent(Bool.self, forKey: .highRefreshRate) ?? highRefreshRate
    }
}

struct PluginFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
