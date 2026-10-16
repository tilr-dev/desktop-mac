import XCTest
import AppKit
import TilrPluginABI
@testable import NativeAudio

private final class Host: NSObject, TLRPluginHost {
    let origin = "tilr://test"
    let viewContainer = NSView()
    let configuration: [String: Any] = [:]
    let storageIdentifier: UUID? = nil
    var events: [[String: Any]] = []
    func persistentIdentifier(_ identifier: UUID) -> UUID { identifier }
    func resolveSiteURL(_ url: URL) -> URL? { nil }
    func emit(_ event: String, detail: [String: Any]) { events.append(detail) }
}

final class LifecycleTests: XCTestCase {
    @MainActor
    func testNativePlayersSurvivePageReloadButNotSessionStop() {
        let host = Host()
        let plugin = AudioPlugin()
        plugin.start(host: host)
        plugin.receive(["op": "create", "id": "music"], channel: "audio")
        XCTAssertEqual(host.events.last?["id"] as? String, "music")
        plugin.pageDidNavigate()
        plugin.receive(["op": "list"], channel: "audio")
        let players = host.events.last?["players"] as? [[String: Any]]
        XCTAssertEqual(players?.count, 1)
        XCTAssertEqual(players?.first?["id"] as? String, "music")
        plugin.stop()
        // Starting a new session on the same object must not adopt disposed players.
        plugin.start(host: host)
        plugin.receive(["op": "list"], channel: "audio")
        XCTAssertEqual((host.events.last?["players"] as? [[String: Any]])?.count, 0)
        plugin.stop()
    }
}
