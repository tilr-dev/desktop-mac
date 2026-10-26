import Foundation
import CryptoKit

/// Server release numbers and channels are independent of Sparkle's app feed.
/// The signed feed retains older compatible releases for older clients.
struct ServerUpdates {
    struct Release: Codable, Equatable {
        let manifest: ServerInstallation.Manifest
        let url: URL
        let size: Int64
    }
    struct Feed: Codable {
        let schema: Int
        let component: String
        let arch: String
        let channel: String
        let releases: [Release]
    }
    struct Envelope: Codable {
        let payload: Data
        let signature: Data
    }
    let feedURL: URL
    let publicKey: Data
    let channel: String
    let arch: String
    let appBuild: Int
    let protocolVersion: Int
    let timeout: TimeInterval
    let maxFeedBytes: Int64
    let maxBinaryBytes: Int64
    /// Tests: stands in for the HTTPS download (url, destination, size limit).
    var fetcher: ((URL, URL, Int64) async throws -> Void)? = nil

    /// A response other than 200.
    struct HTTPStatus: LocalizedError {
        let code: Int
        var errorDescription: String? { "Server update download failed (HTTP \(code))" }
    }
    /// The feed answered, but not with a feed: nothing is published for this channel and architecture.
    struct NoRelease: LocalizedError {
        let channel: String
        let arch: String
        var errorDescription: String? { "No server release is published for \(channel)/\(arch)." }
    }

    /// What a failed check shows: a manual check shows the error; an automatic one shows
    /// nothing (a missing feed or no network must not interrupt local use).
    static func message(for error: Error, userInitiated: Bool) -> String? {
        userInitiated ? error.localizedDescription : nil
    }

    private func fetch(_ url: URL, to file: URL, limit: Int64) async throws {
        if let fetcher { return try await fetcher(url, file, limit) }
        try await ServerDownload.fetch(url, to: file, limit: limit, timeout: timeout)
    }

    func decode(_ data: Data) throws -> Feed {
        guard data.count <= maxFeedBytes else { throw ServerInstallation.Failure("Server update feed is too large") }
        let signed = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signed.signature, for: signed.payload) else {
            throw ServerInstallation.Failure("Server update feed signature is invalid")
        }
        let feed = try JSONDecoder().decode(Feed.self, from: signed.payload)
        guard feed.schema == 1, feed.component == "tilrd", feed.arch == arch, feed.channel == channel else {
            throw ServerInstallation.Failure("Server update feed is for a different component, architecture or channel")
        }
        var builds = Set<Int>()
        for release in feed.releases {
            let m = release.manifest
            guard m.build > 0, builds.insert(m.build).inserted, m.arch == arch,
                  m.protocolVersion > 0, m.minAppBuild > 0,
                  m.maxAppBuild.map({ $0 >= m.minAppBuild }) ?? true,
                  m.sha256.count == 64, m.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
                  !m.version.isEmpty, !m.serverVersion.isEmpty,
                  release.url.scheme == "https", release.url.host != nil,
                  release.size > 0, release.size <= maxBinaryBytes else {
                throw ServerInstallation.Failure("Invalid server release metadata")
            }
        }
        return feed
    }

    func candidate(in feed: Feed, installed: ServerInstallation.Manifest) throws -> Release? {
        if let same = feed.releases.first(where: { $0.manifest.build == installed.build }), same.manifest != installed {
            throw ServerInstallation.Failure("Published server contents changed without a new release number")
        }
        return feed.releases.filter {
            $0.manifest.build > installed.build && $0.manifest.supports(appBuild: appBuild, protocolVersion: protocolVersion, arch: arch)
        }.max { $0.manifest.build < $1.manifest.build }
    }

    func check(installed: ServerInstallation.Manifest) async throws -> Release? {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("feed.json")
        do {
            try await fetch(feedURL, to: file, limit: maxFeedBytes)
        } catch is HTTPStatus {
            throw NoRelease(channel: channel, arch: arch)
        }
        return try candidate(in: decode(Data(contentsOf: file)), installed: installed)
    }

    /// Returns a private staging directory; caller removes it after installation.
    /// Never execute the download before the signed feed's checksum is verified.
    func stage(_ release: Release) async throws -> URL {
        let dir = try temporaryDirectory()
        do {
            let file = dir.appendingPathComponent("tilrd")
            try await fetch(release.url, to: file, limit: release.size)
            try verifyBinary(Data(contentsOf: file), release: release)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try JSONEncoder().encode(release.manifest).write(to: dir.appendingPathComponent("app-managed.json"), options: .atomic)
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    func verifyBinary(_ data: Data, release: Release) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard release.size <= maxBinaryBytes, data.count == release.size, hash == release.manifest.sha256 else {
            throw ServerInstallation.Failure("Downloaded server checksum or size mismatch")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tilrd-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }
}

/// Bound disk usage while streaming; reject HTTP errors and HTTPS → HTTP redirects.
private final class ServerDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let limit: Int64
    var failure: Error?
    var continuation: CheckedContinuation<Void, Error>?
    init(destination: URL, limit: Int64) { self.destination = destination; self.limit = limit }

    static func fetch(_ url: URL, to destination: URL, limit: Int64, timeout: TimeInterval) async throws {
        guard url.scheme == "https" else { throw ServerInstallation.Failure("Server downloads require HTTPS") }
        let delegate = ServerDownload(destination: destination, limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            session.downloadTask(with: request).resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            failure = ServerInstallation.Failure("Server download exceeds its size limit")
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.url?.scheme == "https" else {
                throw ServerInstallation.Failure("Server update download failed (no HTTPS response)")
            }
            guard response.statusCode == 200 else { throw ServerUpdates.HTTPStatus(code: response.statusCode) }
            let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
            guard let size, size.int64Value <= limit else { throw ServerInstallation.Failure("Server download exceeds its size limit") }
            if let failure { throw failure }
            try FileManager.default.copyItem(at: location, to: destination)
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }
}
