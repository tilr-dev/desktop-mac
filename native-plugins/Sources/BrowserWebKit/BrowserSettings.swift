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

    enum CodingKeys: String, CodingKey {
        case userAgent = "user_agent"
        case tunnelChunk = "tunnel_chunk"
        case automationTimeout = "automation_timeout"
        case automationPrivateInput = "automation_private_input"
        case automationInputInterval = "automation_input_interval"
    }
}

struct PluginFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
