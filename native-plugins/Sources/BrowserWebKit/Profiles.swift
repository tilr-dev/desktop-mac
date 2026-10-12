import Foundation
import TilrPluginABI
import Network
import WebKit

/// A web view's profile, as the page sends it with `create` (`WebViewProfile` in the web repo's
/// types): `id`, a UUID naming the data store (cookies, storage, cache), the same across
/// launches; `proxy`, where the store's connections go; `localhost`, the host a navigation to
/// `localhost` / `127.*` / `[::1]` goes to instead (WebKit never sends those through a proxy).
struct Profile {
    let id: String
    let proxy: Proxy?
    let localhost: String?

    /// nil for a body that is not a profile (no `id`): the default store.
    init?(_ body: Any?) {
        guard let body = body as? [String: Any], let id = body["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        proxy = Proxy(body["proxy"])
        localhost = (body["localhost"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A profile's proxy (`WebViewProxy`): a SOCKS5 or HTTP CONNECT server, or a tilr server's
/// `/socks` endpoint (a tunnel, see Tunnel.swift). `match`: only these hosts and their subdomains
/// go through it (empty: all); `exclude`: these go direct.
struct Proxy: Equatable {
    enum Kind: Equatable {
        case socks5(host: String, port: UInt16, user: String?, pass: String?)
        case http(host: String, port: UInt16, user: String?, pass: String?)
        case tunnel(url: URL, token: String)
    }

    let kind: Kind
    let match: [String]
    let exclude: [String]

    init?(_ body: Any?) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
        let host = body["host"] as? String ?? ""
        let port = (body["port"] as? NSNumber).map { UInt16(clamping: $0.intValue) } ?? 0
        let user = body["user"] as? String, pass = body["pass"] as? String
        switch kind {
        case "socks5" where !host.isEmpty && port > 0: self.kind = .socks5(host: host, port: port, user: user, pass: pass)
        case "http" where !host.isEmpty && port > 0: self.kind = .http(host: host, port: port, user: user, pass: pass)
        case "tunnel":
            guard let text = body["url"] as? String, let url = URL(string: text), let token = body["token"] as? String else { return nil }
            self.kind = .tunnel(url: url, token: token)
        default:
            print("webviews: not a proxy: \(body)")
            return nil
        }
        match = body["match"] as? [String] ?? []
        exclude = body["exclude"] as? [String] ?? []
    }

    /// What the page calls it: 'socks5', 'http' or 'tunnel'.
    var name: String {
        switch kind {
        case .socks5: "socks5"
        case .http: "http"
        case .tunnel: "tunnel"
        }
    }

    /// The store's proxy configuration; a tunnel's is its listener on `port`.
    func configuration(port tunnelPort: UInt16?) -> ProxyConfiguration? {
        var made: ProxyConfiguration
        var credential: (String, String)?
        switch kind {
        case let .socks5(host, port, user, pass):
            made = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(host), port: .init(integerLiteral: port)))
            if user != nil || pass != nil { credential = (user ?? "", pass ?? "") }
        case let .http(host, port, user, pass):
            made = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(host), port: .init(integerLiteral: port)))
            if user != nil || pass != nil { credential = (user ?? "", pass ?? "") }
        case .tunnel:
            guard let tunnelPort else { return nil }
            made = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: .init(integerLiteral: tunnelPort)))
        }
        if let (user, pass) = credential { made.applyCredential(username: user, password: pass) }
        if !match.isEmpty { made.matchDomains = match }
        if !exclude.isEmpty { made.excludedDomains = exclude }
        return made
    }
}

/// The profiles' data stores and the tunnels, shared by every tab: one store per profile id, made
/// with the first view of the profile and kept while the app runs; one tunnel per endpoint and
/// token, shared by the profiles that name the same pair and stopped when its last view goes.
/// A view takes a `Lease` (`join`) and gives it back when it goes.
final class Profiles {
    static let shared = Profiles()

    private final class Store {
        let data: WKWebsiteDataStore
        /// The proxy set on the store and the tunnel port it went to; nil: none set yet.
        var applied: (proxy: Proxy?, port: UInt16?)?
        init(_ data: WKWebsiteDataStore) { self.data = data }
    }

    private struct TunnelKey: Hashable {
        let url: URL
        let token: String
    }

    private var stores: [String: Store] = [:]
    private struct Weak { weak var lease: Lease? }
    private var tunnels: [TunnelKey: (tunnel: Tunnel, users: [ObjectIdentifier: Weak])] = [:]

    /// The store of `profile`, nil for the instance's own (Instance.store), with its proxy (set before the view's
    /// first load: `Lease.ready`). `origin` is the page's, sent by a tunnel's handshake; `chunk`
    /// the tunnel's read size.
    func join(_ profile: Profile?, host: TLRPluginHost, origin: String, chunk: Int) -> Lease {
        guard let profile else { return Lease(store: defaultStore(host), profile: nil) }
        let store = store(profile.id, host: host)
        let lease = Lease(store: store.data, profile: profile)
        guard let proxy = profile.proxy else {
            apply(nil, port: nil, to: store, profile: profile.id)
            lease.settle(nil)
            return lease
        }
        guard case let .tunnel(url, token) = proxy.kind else {
            apply(proxy, port: nil, to: store, profile: profile.id)
            lease.settle(nil)
            return lease
        }
        let key = TunnelKey(url: url, token: token)
        let tunnel: Tunnel
        if let entry = tunnels[key] {
            tunnel = entry.tunnel
        } else {
            tunnel = Tunnel(url: url, token: token, origin: origin, chunk: chunk)
            tunnel.status = { [weak self] error in self?.report(error, from: key) }
            tunnel.start()
            tunnels[key] = (tunnel, [:])
        }
        tunnels[key]?.users[ObjectIdentifier(lease)] = Weak(lease: lease)
        lease.leave = { [weak self, weak lease] in
            guard let self, let lease else { return }
            self.leave(lease, key)
        }
        tunnel.whenReady { [weak self, weak lease] port, failure in
            guard let self, let lease else { return }
            if let port { self.apply(proxy, port: port, to: store, profile: profile.id) }
            lease.settle(failure)
        }
        return lease
    }

    private var defaultData: WKWebsiteDataStore?
    private func defaultStore(_ host: TLRPluginHost) -> WKWebsiteDataStore {
        if let defaultData { return defaultData }
        let data = host.storageIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
        defaultData = data
        return data
    }

    private func store(_ id: String, host: TLRPluginHost) -> Store {
        if let store = stores[id] { return store }
        let data: WKWebsiteDataStore
        if let uuid = UUID(uuidString: id) {
            data = WKWebsiteDataStore(forIdentifier: host.persistentIdentifier(uuid))
        } else {
            // Not a UUID, so it cannot name a store on disk: one in memory, gone with the app.
            print("webviews: profile id \(id) is not a UUID; its storage is kept in memory")
            data = .nonPersistent()
        }
        let store = Store(data)
        stores[id] = store
        return store
    }

    /// Sets `proxy` on the store when it is not what the store has. Before the first load it is
    /// the store's from the start; later only new connections take it (open ones stay as they are).
    private func apply(_ proxy: Proxy?, port: UInt16?, to store: Store, profile: String) {
        if let applied = store.applied, applied.proxy == proxy, applied.port == port { return }
        if store.applied != nil { print("webviews: profile \(profile): proxy now \(proxy?.name ?? "none"), for new connections") }
        store.applied = (proxy, port)
        store.data.proxyConfigurations = proxy?.configuration(port: port).map { [$0] } ?? []
    }

    private func leave(_ lease: Lease, _ key: TunnelKey) {
        guard var entry = tunnels[key] else { return }
        entry.users[ObjectIdentifier(lease)] = nil
        if entry.users.isEmpty {
            entry.tunnel.stop()
            tunnels[key] = nil
        } else {
            tunnels[key] = entry
        }
    }

    /// A tunnel's handshake outcome, to the views of the leases on it.
    private func report(_ error: String?, from key: TunnelKey) {
        guard let users = tunnels[key]?.users.values else { return }
        for user in users { user.lease?.status?(error) }
    }
}

/// A view's hold on its profile: the store to make the web view with, and, for a view with a
/// proxy, when it may load (`ready`) and how its tunnel fares (`status`). Given back with `end`.
final class Lease {
    let store: WKWebsiteDataStore
    let profile: Profile?
    /// A tunnel's last handshake: an error, or nil when one went through. Main queue.
    var status: ((String?) -> Void)?
    fileprivate var leave: (() -> Void)?
    private var settled: String??
    private var waiting: [(String?) -> Void] = []

    fileprivate init(store: WKWebsiteDataStore, profile: Profile?) {
        self.store = store
        self.profile = profile
        if profile?.proxy == nil { settled = .some(nil) }
    }

    /// Calls `done` once the store has the proxy (at once when it has): nil, or why the proxy
    /// is not there (a tunnel whose listener failed), and then the view must not load.
    func ready(_ done: @escaping (String?) -> Void) {
        if let settled { return done(settled) }
        waiting.append(done)
    }

    fileprivate func settle(_ failure: String?) {
        guard settled == nil else { return }
        settled = .some(failure)
        let waiting = self.waiting
        self.waiting = []
        for done in waiting { done(failure) }
    }

    func end() {
        status = nil
        waiting = []
        leave?()
        leave = nil
    }
}
