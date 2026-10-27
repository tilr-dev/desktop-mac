import Foundation
import CryptoKit

@main struct ServerUpdateTests {
    static func main() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let updater = ServerUpdates(feedURL: URL(string: "https://cdn.example/stable.json")!,
            publicKey: key.publicKey.rawRepresentation, channel: "stable", arch: "arm64", appBuild: 10,
            protocolVersion: 1, timeout: 10, maxFeedBytes: 1048576, maxBinaryBytes: 1024)
        let bytes = Data("signed server bytes".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        func release(_ build: Int, proto: Int = 1, min: Int = 1, max: Int? = nil) -> ServerUpdates.Release {
            let m = ServerInstallation.Manifest(version: "0.1", build: build, arch: "arm64", serverVersion: "0.1-build\(build)",
                sha256: hash, protocolVersion: proto, minAppBuild: min, maxAppBuild: max)
            return .init(manifest: m, url: URL(string: "https://cdn.example/server-\(build)")!, size: Int64(bytes.count))
        }
        func envelope(_ releases: [ServerUpdates.Release], channel: String = "stable", component: String = "tilrd") throws -> Data {
            let feed = ServerUpdates.Feed(schema: 1, component: component, arch: "arm64", channel: channel, releases: releases)
            let payload = try JSONEncoder().encode(feed)
            return try JSONEncoder().encode(ServerUpdates.Envelope(payload: payload, signature: key.signature(for: payload)))
        }
        func reject(_ body: () throws -> Void) { do { try body(); fatalError("expected refusal") } catch {} }
        func expect(_ condition: Bool) { precondition(condition) }
        let initial = release(1).manifest
        let wire = try envelope([release(6, proto: 2), release(5, min: 11), release(4, max: 15), release(3, max: 9), release(1)])
        let feed = try updater.decode(wire)
        expect(try updater.candidate(in: feed, installed: initial)?.manifest.build == 4)
        expect(try updater.candidate(in: feed, installed: release(7).manifest) == nil)
        // Ordinary installations without feed receipts must not be offered older releases.
        let ordinary = ServerInstallation.Manifest(version: "9.0", build: 0, arch: "arm64", serverVersion: "9.0-new", sha256: hash, protocolVersion: 1, minAppBuild: 0, maxAppBuild: nil)
        expect(try updater.candidate(in: feed, installed: ordinary) == nil)
        // App and server build numbers have no ordering relationship.
        expect(release(500).manifest.supports(appBuild: 10, protocolVersion: 1, arch: "arm64"))
        for protocolVersion in [0, 2, 3] {
            expect(!release(500, proto: protocolVersion).manifest.supports(appBuild: 10, protocolVersion: 1, arch: "arm64"))
            if protocolVersion == 0 {
                reject { _ = try updater.decode(envelope([release(500, proto: protocolVersion)])) }
            } else {
                let incompatibleFeed = try updater.decode(envelope([release(500, proto: protocolVersion)]))
                expect(try updater.candidate(in: incompatibleFeed, installed: initial) == nil)
            }
        }
        for component in ["tilr-server", "other"] {
            reject { _ = try updater.decode(envelope([release(2)], component: component)) }
        }
        reject { _ = try updater.decode(envelope([release(2)], channel: "beta")) }
        reject { _ = try updater.decode(envelope([release(2), release(2)])) }
        var signed = try JSONDecoder().decode(ServerUpdates.Envelope.self, from: wire)
        signed = .init(payload: signed.payload + Data([32]), signature: signed.signature)
        reject { _ = try updater.decode(JSONEncoder().encode(signed)) }
        let different = release(1, min: 2)
        reject { _ = try updater.candidate(in: updater.decode(envelope([different])), installed: initial) }
        try updater.verifyBinary(bytes, release: release(2))
        reject { try updater.verifyBinary(bytes.dropLast(), release: release(2)) }
        reject { try updater.verifyBinary(Data(repeating: 65, count: bytes.count), release: release(2)) }
        // A feed that answers 404 is "nothing published"; a binary that does is a failed download.
        var missing = updater
        missing.fetcher = { _, _, _ in throw ServerUpdates.HTTPStatus(code: 404) }
        let noRelease = await failure { _ = try await missing.check(installed: initial) }
        expect(noRelease is ServerUpdates.NoRelease)
        expect(noRelease?.localizedDescription == "No server release is published for stable/arm64.")
        // A manual check shows that sentence; an automatic one shows nothing.
        expect(ServerUpdates.message(for: noRelease!, userInitiated: true) == "No server release is published for stable/arm64.")
        expect(ServerUpdates.message(for: noRelease!, userInitiated: false) == nil)
        let download = await failure { _ = try await missing.stage(release(2)) }
        expect(download?.localizedDescription == "Server update download failed (HTTP 404)")
        var served = updater
        served.fetcher = { _, file, _ in try wire.write(to: file) }
        expect(try await served.check(installed: initial)?.manifest.build == 4)
        print("server updates: signed feeds, tampering, channels, duplicate builds, protocol/app compatibility, no downgrade, payload integrity, feed 404 = no release (manual shows it, automatic silent), binary 404 = download failure: passed")
    }

    static func failure(_ body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }
}
