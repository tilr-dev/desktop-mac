import Foundation
import WebKit

/// The user's SSH agent for the page: the page (the `sshagent` service of the web repo) forwards
/// it to a tilr server's panes, as `ssh -A` does. The app only pipes bytes between the agent's
/// unix socket and the page; it reads nothing of the protocol. The page posts `{ op, … }` to
/// `webkit.messageHandlers.tilrAgent`:
///
///   probe                 → `{ type: 'ready', available, path?, error? }`: whether the agent's
///                         socket was found (see `resolve`) and a connection to it went through
///                         (it is closed again at once)
///   open   id             a connection to the agent for `id` (a string the page picks)
///                         → `{ type: 'open', id }`, or `{ type: 'close', id, error }`
///   data   id data        `data` (base64) written to that connection
///   close  id             shuts the connection down; no answer
///
/// and the app answers with a `tilr-agent` CustomEvent on the page's `window`, `detail` being
/// `{ type: 'ready', … }` as above, `{ type: 'open', id }`, `{ type: 'data', id, data }` (base64
/// of what the agent sent, at most `ssh_agent.chunk` bytes per event) or `{ type: 'close', id,
/// error? }` when the agent closed the connection or it failed. After a close from either side
/// nothing more comes for that id. At most `ssh_agent.max_streams` connections per page; an
/// `open` over that is answered with a close and an error.
///
/// Connections are the page's: a navigation or a reload closes them all, without events.
///
/// The agent is exposed to whatever the page forwards it to: a server holding the forwarded
/// agent can ask it to sign while the connection is open, as with `ssh -A`. The page is ours
/// (`tilr://`), nothing else is checked here; an agent that asks per signature (1Password, when
/// set up so) still asks.
///
/// Everything on the main queue except the sockets' own work (connect, read, write), which is on
/// queues of their own and comes back to the main queue to report.
final class AgentHost: NSObject, WKScriptMessageHandler {
    static let name = "tilrAgent"
    static let event = "tilr-agent"

    /// Dispatches a `tilr-agent` event with this detail on the page.
    var send: ([String: Any]) -> Void = { _ in }
    var settings: Config.SSHAgent

    private var streams: [String: AgentStream] = [:]
    /// Resolving the socket and connecting.
    private let queue = DispatchQueue(label: "tilr.agent")

    init(settings: Config.SSHAgent) {
        self.settings = settings
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handle(message.body)
    }

    /// One message of the page.
    func handle(_ message: Any) {
        guard let body = message as? [String: Any], let op = body["op"] as? String else {
            print("agent: a message without op:", message)
            return
        }
        if op == "probe" {
            let configured = settings.socket
            queue.async { [weak self] in
                let (path, error) = Self.resolve(configured)
                var detail: [String: Any] = ["type": "ready"]
                if let path { detail["path"] = path }
                var failure = error
                if let path, failure == nil {
                    do { Darwin.close(try Self.connect(path)) } catch { failure = "\(error)" }
                }
                detail["available"] = failure == nil
                if let failure { detail["error"] = failure }
                DispatchQueue.main.async { self?.send(detail) }
            }
            return
        }
        guard let id = body["id"] as? String else {
            print("agent: \(op) without id")
            return
        }
        switch op {
        case "open": open(id)
        case "data":
            guard let stream = streams[id] else { return print("agent: data for unknown connection \(id)") }
            guard let text = body["data"] as? String, let data = Data(base64Encoded: text) else {
                print("agent: data \(id) without base64 data")
                return finish(id, error: "data is not base64")
            }
            stream.write(data)
        case "close":
            streams.removeValue(forKey: id)?.stop()
        default:
            print("agent: unknown op \(op)")
        }
    }

    private func open(_ id: String) {
        guard streams[id] == nil else {
            return send(["type": "close", "id": id, "error": "connection \(id) is open already"])
        }
        guard streams.count < settings.maxStreams else {
            return send(["type": "close", "id": id, "error": "too many agent connections (ssh_agent.max_streams: \(settings.maxStreams))"])
        }
        // Counted from now on, so opens in a row cannot get past the cap while connecting.
        let stream = AgentStream(id: id, chunk: max(1, settings.chunk))
        streams[id] = stream
        let configured = settings.socket
        queue.async { [weak self, stream] in
            let (path, error) = Self.resolve(configured)
            let result: Result<Int32, Error>
            if let path, error == nil {
                result = Result { try Self.connect(path) }
            } else {
                result = .failure(AgentError(error ?? "no agent socket"))
            }
            DispatchQueue.main.async {
                guard let self, self.streams[id] === stream else {
                    // Closed by the page (or the page left) while connecting.
                    if case .success(let fd) = result { Darwin.close(fd) }
                    return
                }
                switch result {
                case .success(let fd):
                    stream.start(fd: fd, received: { [weak self, weak stream] data in
                        guard let self, let stream, self.streams[id] === stream else { return }
                        self.send(["type": "data", "id": id, "data": data.base64EncodedString()])
                    }, ended: { [weak self, weak stream] error in
                        guard let self, let stream, self.streams[id] === stream else { return }
                        self.finish(id, error: error)
                    })
                    self.send(["type": "open", "id": id])
                case .failure(let error):
                    self.streams[id] = nil
                    self.send(["type": "close", "id": id, "error": "\(error)"])
                }
            }
        }
    }

    /// Drops the connection and tells the page, once.
    private func finish(_ id: String, error: String?) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        stream.stop()
        var detail: [String: Any] = ["type": "close", "id": id]
        if let error { detail["error"] = error }
        send(detail)
    }

    /// The page is leaving: every connection goes, without events (there is no page to get them).
    func closeAll() {
        for stream in streams.values { stream.stop() }
        streams.removeAll()
    }

    // MARK: The agent's socket

    /// The agent's socket: `configured` (`~` expanded) when it is not empty, else the first of
    /// these that exists: `SSH_AUTH_SOCK` of the app's environment, `IdentityAgent` of
    /// `~/.ssh/config`, 1Password's agent, `launchctl getenv SSH_AUTH_SOCK`. An app started from
    /// Finder does not have the shell's environment, hence the list. Returns the path, or nil and why.
    static func resolve(_ configured: String) -> (String?, String?) {
        if !configured.isEmpty { return ((configured as NSString).expandingTildeInPath, nil) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [() -> String?] = [
            { ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] },
            { identityAgent(home: home) },
            { home + "/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" },
            { launchdAuthSock() },
        ]
        for candidate in candidates {
            if let path = candidate(), !path.isEmpty, FileManager.default.fileExists(atPath: path) { return (path, nil) }
        }
        return (nil, "no SSH agent socket: none of SSH_AUTH_SOCK, IdentityAgent in ~/.ssh/config, 1Password's agent, launchctl's SSH_AUTH_SOCK exists")
    }

    /// The first `IdentityAgent` of `~/.ssh/config` that applies to every host: before the first
    /// `Host`/`Match`, or under `Host *`. `none` and `SSH_AUTH_SOCK` say nothing here.
    static func identityAgent(home: String) -> String? {
        guard let text = try? String(contentsOfFile: home + "/.ssh/config", encoding: .utf8) else { return nil }
        var global = true
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            var value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            switch key {
            case "host": global = value.split(separator: " ").contains("*")
            case "match": global = value.lowercased() == "all"
            case "identityagent" where global:
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                if value.lowercased() == "none" || value == "SSH_AUTH_SOCK" || value == "$SSH_AUTH_SOCK" { continue }
                if value == "~" || value.hasPrefix("~/") { value = home + value.dropFirst() }
                return value
            default: break
            }
        }
        return nil
    }

    /// The per-user launchd's `SSH_AUTH_SOCK` (the system's agent).
    static func launchdAuthSock() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// A connected unix stream socket (blocking, no SIGPIPE).
    static func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw AgentError("\(path): path too long for a unix socket") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AgentError("connect \(path): \(why)")
        }
        return fd
    }
}

struct AgentError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One connection to the agent: reads whenever the socket has bytes (on its read queue), writes
/// in order (on its write queue), and closes the socket once both are done with it.
final class AgentStream {
    let id: String
    let chunk: Int
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1
    /// The write queue's: the socket is closed, writes are dropped.
    private var closed = false

    init(id: String, chunk: Int) {
        self.id = id
        self.chunk = chunk
        readQueue = DispatchQueue(label: "tilr.agent.read")
        writeQueue = DispatchQueue(label: "tilr.agent.write")
    }

    /// Starts reading `fd`; `received` and `ended` (nil: the agent closed it) come on the main queue.
    func start(fd: Int32, received: @escaping (Data) -> Void, ended: @escaping (String?) -> Void) {
        self.fd = fd
        let chunk = chunk
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        var buffer = [UInt8](repeating: 0, count: chunk)
        var done = false
        source.setEventHandler {
            guard !done else { return }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            if count > 0 {
                let data = Data(buffer[0..<count])
                DispatchQueue.main.async { received(data) }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                done = true
                let error = count == 0 ? nil : "read: \(String(cString: strerror(errno)))"
                DispatchQueue.main.async { ended(error) }
            }
        }
        let writeQueue = writeQueue
        source.setCancelHandler { [self] in
            writeQueue.async { [self] in
                closed = true
                Darwin.close(fd)
            }
        }
        self.source = source
        source.resume()
    }

    func write(_ data: Data) {
        writeQueue.async { [self] in
            guard !closed, fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        // The read side sees the socket fail or close and reports it.
                        shutdown(fd, SHUT_RDWR)
                        return
                    }
                    offset += written
                }
            }
        }
    }

    /// Stops reading and closes the socket after the writes queued before.
    func stop() {
        if let source {
            source.cancel()
            self.source = nil
        }
    }
}
