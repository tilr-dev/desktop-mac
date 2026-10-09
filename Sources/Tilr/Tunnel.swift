import Foundation
import Network

/// A tilr server's SOCKS endpoint (`wss://…/socks`) as a SOCKS5 proxy on this machine, for
/// WebKit, which only takes a host and a port: a listener on 127.0.0.1 (a port of the system's
/// choosing), and per connection accepted a WebSocket to the endpoint, the SOCKS bytes carried
/// both ways in binary messages, one WebSocket per connection (the server does not multiplex).
/// The server's handshake decides: 101 and the bytes flow, 401 (the token), 403 (the origin),
/// 404 (no SOCKS on that server), or a dead server behind Cloudflare's 502 / 530; `status` tells
/// the last outcome, an error or nil after a handshake that went through.
///
/// One chunk at a time each way: the next one is read when the one before has been sent, so a
/// slow side holds the other back and nothing piles up in between. A text message, a close or a
/// failure of the WebSocket closes the connection; the connection's end closes the WebSocket
/// (1000), and the server closes the target.
///
/// The listener asks for no authentication: while the app runs, any process of this machine can
/// use it to reach what the server reaches. It is bound to the loopback only; accepted for now.
final class Tunnel: NSObject, URLSessionWebSocketDelegate {
    let url: URL
    let token: String
    /// The Origin the handshake sends: the app's own (`tilr://<app>`), one the server allows.
    let origin: String
    /// Bytes read from a connection at a time, the most one message carries.
    let chunk: Int
    /// The last handshake's outcome: an error (`'401 bad token'`), nil after one that went
    /// through. Called on the main queue.
    var status: ((String?) -> Void)?

    /// The listener's port once it listens; on the main queue.
    private(set) var port: UInt16?
    private var failure: String?
    private var waiting: [(UInt16?, String?) -> Void] = []

    /// Everything else is the tunnel's queue's.
    private let queue = DispatchQueue(label: "tilr.tunnel")
    private var listener: NWListener?
    private var session: URLSession!
    private var bridges: [Int: Bridge] = [:]

    init(url: URL, token: String, origin: String, chunk: Int) {
        self.url = url
        self.token = token
        self.origin = origin
        self.chunk = chunk
        super.init()
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: operations)
    }

    /// Starts listening; `ready` gets the port, or nil and why there is none.
    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return settle(nil, "listener: \(error.localizedDescription)")
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue
                DispatchQueue.main.async { self?.settle(port, port == nil ? "listener: no port" : nil) }
            case .failed(let error):
                DispatchQueue.main.async { self?.settle(nil, "listener: \(error.localizedDescription)") }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    /// Calls `done` with the port once the listener has one (at once when it has), or nil and the
    /// listener's error. On the main queue.
    func whenReady(_ done: @escaping (UInt16?, String?) -> Void) {
        if port != nil || failure != nil { return done(port, failure) }
        waiting.append(done)
    }

    private func settle(_ port: UInt16?, _ failure: String?) {
        guard self.port == nil, self.failure == nil else { return }
        self.port = port
        self.failure = failure
        if let failure { print("tunnel \(url.absoluteString): \(failure)") }
        let waiting = self.waiting
        self.waiting = []
        for done in waiting { done(port, failure) }
    }

    /// Closes the listener and every connection; the tunnel is done.
    func stop() {
        status = nil
        waiting = []
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for bridge in bridges.values { bridge.close() }
            bridges.removeAll()
            session.invalidateAndCancel()
        }
    }

    // MARK: Connections (the tunnel's queue)

    private func accept(_ connection: NWConnection) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        let bridge = Bridge(connection: connection, task: task, chunk: chunk, queue: queue) { [weak self] id in
            self?.bridges[id] = nil
        }
        bridges[task.taskIdentifier] = bridge
        connection.start(queue: queue)
        task.resume()
    }

    private func report(_ error: String?) {
        DispatchQueue.main.async { [weak self] in self?.status?(error) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        report(nil)
        bridges[webSocketTask.taskIdentifier]?.opened()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let bridge = bridges[task.taskIdentifier] else { return }
        if !bridge.isOpen, let error {
            report(Tunnel.describe(task.response as? HTTPURLResponse, error))
        }
        bridge.close()
    }

    /// A failed handshake in a few words, the status first.
    static func describe(_ response: HTTPURLResponse?, _ error: Error) -> String {
        guard let code = response?.statusCode else { return error.localizedDescription }
        switch code {
        case 401: return "401 bad token"
        case 403: return "403 origin not allowed"
        case 404: return "404 no SOCKS on this server"
        case 502, 530: return "\(code) the server is not reachable"
        default: return "\(code) \(HTTPURLResponse.localizedString(forStatusCode: code))"
        }
    }
}

/// One connection of WebKit's and its WebSocket. Only touched on the tunnel's queue.
private final class Bridge {
    let connection: NWConnection
    let task: URLSessionWebSocketTask
    let chunk: Int
    let queue: DispatchQueue
    private let ended: (Int) -> Void
    private(set) var isOpen = false
    private var closed = false

    init(connection: NWConnection, task: URLSessionWebSocketTask, chunk: Int, queue: DispatchQueue, ended: @escaping (Int) -> Void) {
        self.connection = connection
        self.task = task
        self.chunk = chunk
        self.queue = queue
        self.ended = ended
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
    }

    /// The handshake went through: the bytes start to flow, each way one chunk at a time.
    func opened() {
        isOpen = true
        upstream()
        downstream()
    }

    /// The connection's next chunk to the WebSocket; its end closes the WebSocket.
    private func upstream() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunk) { [weak self] data, _, complete, error in
            guard let self, !closed else { return }
            if let data, !data.isEmpty {
                task.send(.data(data)) { [weak self] error in
                    self?.queue.async {
                        guard let self, !self.closed else { return }
                        if error != nil { return self.close() }
                        if complete { return self.finish() }
                        self.upstream()
                    }
                }
            } else if complete || error != nil {
                finish()
            } else {
                upstream()
            }
        }
    }

    /// The WebSocket's next message to the connection; a text message, a close or an error ends it.
    private func downstream() {
        task.receive { [weak self] result in
            self?.queue.async {
                guard let self, !self.closed else { return }
                guard case .success(.data(let data)) = result else { return self.drain() }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil { return self.close() }
                    self.downstream()
                })
            }
        }
    }

    /// The connection ended: the WebSocket closes normally, the server closes the target.
    private func finish() {
        task.cancel(with: .normalClosure, reason: nil)
        close()
    }

    /// The WebSocket ended: what was sent to the connection goes out, then its end.
    private func drain() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        ended(task.taskIdentifier)
    }
}
