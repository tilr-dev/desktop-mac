import AVFoundation
import MediaPlayer
import Foundation

/// Audio that lives in the app, not in the page: a page reload or a plugin reload leaves it
/// playing. One AVPlayer per `id` (a key the page picks). The page posts `{ op, … }` to
/// `webkit.messageHandlers.tilrAudio`:
///
///   list                          → `{ type: 'list', players: [report…] }`
///   create   id                   the player if there is none; either way a report
///   load     id url title? artist?   a new item (stopped at 0); `tilr://<app>/path` plays the
///                                 app's file, http(s) and file URLs go to AVPlayer as they are
///   play | pause | stop (pause + back to 0)   id
///   seek     id position (s)
///   volume   id volume (0…1)
///   balance  id balance; eq id enabled preamp bands   accepted, ignored for now
///   dispose  id                   stops and drops the player
///
/// and the app answers with a `tilr-audio` CustomEvent on the page's `window`, `detail` being a
/// report `{ type: 'state', id, status: stopped|playing|paused, url, position (s), at (ms since
/// 1970), rate: 0|1, duration (s, 0 until known), stalled, volume }` on every change (never
/// periodically: the page runs the clock from `position`, `at` and `rate`), `{ type: 'ended', id }`
/// at the end of the item (then a stopped report at 0), `{ type: 'error', id, message }`, or
/// `{ type: 'command', id, command: next|previous }` from the media keys / Now Playing.
///
/// The players are not touched when the page navigates; `list` after a reload finds them.
/// Now Playing and the media keys follow the player that was played last (NowPlaying).
///
/// Desktop implementation. iPad keeps its built-in implementation; no runtime modules there.
@MainActor
final class AudioHost: NSObject {
    static let name = "tilrAudio"
    static let event = "tilr-audio"

    /// Dispatches a `tilr-audio` event with this detail on the page.
    var send: ([String: Any]) -> Void = { _ in }
    /// `tilr://<host>/<path>` → the file it serves, nil when there is none.
    var siteFile: (URL) -> URL? = { _ in nil }

    private var players: [String: AudioPlayer] = [:]

    func stopAll() {
        for player in players.values { player.dispose() }
        players.removeAll()
        send = { _ in }
        siteFile = { _ in nil }
    }

    /// One message of the page.
    func handle(_ message: Any) {
        guard let body = message as? [String: Any], let op = body["op"] as? String else {
            print("audio: a message without op:", message)
            return
        }
        if op == "list" {
            send(["type": "list", "players": players.keys.sorted().compactMap { players[$0]?.report() }])
            return
        }
        guard let id = body["id"] as? String else {
            print("audio: \(op) without id")
            return
        }
        if op == "create" {
            let player = players[id] ?? make(id)
            player.reportState()
            return
        }
        guard let player = players[id] else {
            print("audio: \(op) for unknown player \(id)")
            send(["type": "error", "id": id, "message": "no player \(id)"])
            return
        }
        switch op {
        case "load":
            guard let text = body["url"] as? String, let url = URL(string: text) else {
                print("audio: load \(id) without a url")
                player.fail("load without a url")
                return
            }
            guard let playable = playable(url) else {
                print("audio: load \(id): no file for \(text)")
                player.fail("no file for \(text)")
                return
            }
            player.load(url: text, playable: playable, title: body["title"] as? String, artist: body["artist"] as? String)
        case "play": player.play()
        case "pause": player.pause()
        case "stop": player.stop()
        case "seek":
            guard let position = (body["position"] as? NSNumber)?.doubleValue else { return print("audio: seek \(id) without position") }
            player.seek(position)
        case "volume":
            guard let volume = (body["volume"] as? NSNumber)?.doubleValue else { return print("audio: volume \(id) without volume") }
            player.setVolume(volume)
        case "balance", "eq":
            break  // v1: accepted and ignored
        case "dispose":
            player.dispose()
            players[id] = nil
        default:
            print("audio: unknown op \(op)")
        }
    }

    private func make(_ id: String) -> AudioPlayer {
        let player = AudioPlayer(id: id) { [weak self] in self?.send($0) }
        players[id] = player
        return player
    }

    /// What AVPlayer can open: the site's own scheme is WKWebView's, so it is played from the file.
    private func playable(_ url: URL) -> URL? {
        url.scheme == "tilr" ? siteFile(url) : url
    }


}

/// One `id`: an AVPlayer with one item at a time.
@MainActor
final class AudioPlayer {
    enum Status: String { case stopped, playing, paused }

    let id: String
    let player = AVPlayer()
    private let post: ([String: Any]) -> Void
    private(set) var url: String?
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var status = Status.stopped
    private(set) var duration = 0.0
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemTokens: [NSObjectProtocol] = []
    /// The timeControlStatus last reported: KVO repeats a value it already had.
    private var control: AVPlayer.TimeControlStatus?
    /// A seek in flight reports when it lands, not on the way (the pause at the end of an item).
    private var seeking = 0

    init(id: String, post: @escaping ([String: Any]) -> Void) {
        self.id = id
        self.post = post
        player.actionAtItemEnd = .pause
        // Stall start and end, and the clock actually running.
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.controlChanged() }
        })
    }

    /// AVPlayer's waiting while play() was asked for: buffering.
    var stalled: Bool { status == .playing && player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var rate: Int { status == .playing && player.timeControlStatus == .playing ? 1 : 0 }
    var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    func report() -> [String: Any] {
        [
            "type": "state", "id": id, "status": status.rawValue, "url": url.map { $0 as Any } ?? NSNull(),
            "position": position, "at": Date().timeIntervalSince1970 * 1000, "rate": rate,
            "duration": duration, "stalled": stalled, "volume": Double(player.volume),
        ]
    }

    func reportState() {
        control = player.timeControlStatus
        post(report())
        NowPlaying.shared.changed(self)
    }

    /// next / previous from the media keys: the page picks the track.
    func command(_ name: String) {
        post(["type": "command", "id": id, "command": name])
    }

    func fail(_ message: String) {
        post(["type": "error", "id": id, "message": message])
    }

    func load(url: String, playable: URL, title: String?, artist: String?) {
        player.pause()
        dropItem()
        self.url = url
        self.title = title
        self.artist = artist
        status = .stopped
        duration = 0
        let item = AVPlayerItem(url: playable)
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        })
        itemObservations.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.durationChanged(item) }
        })
        let center = NotificationCenter.default
        itemTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        })
        itemTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "failed to play to the end"
            MainActor.assumeIsolated { self?.failed(message) }
        })
        player.replaceCurrentItem(with: item)
        reportState()
    }

    func play() {
        guard let item = player.currentItem else { return fail("nothing loaded") }
        guard item.status != .failed else { return fail(item.error?.localizedDescription ?? "the item failed") }
        NowPlaying.shared.played(self)
        status = .playing
        player.play()
        reportState()
    }

    func pause() {
        guard status == .playing else { return reportState() }
        status = .paused
        player.pause()
        reportState()
    }

    func stop() {
        player.pause()
        status = .stopped
        rewind()
    }

    func seek(_ position: Double) {
        let time = CMTime(seconds: max(0, position.isFinite ? position : 0), preferredTimescale: 1000)
        seeking += 1
        Task { @MainActor in
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            seeking -= 1
            reportState()
        }
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(min(1, max(0, volume.isFinite ? volume : 1)))
        reportState()
    }

    func dispose() {
        player.pause()
        dropItem()
        player.replaceCurrentItem(with: nil)
        status = .stopped
        observations.removeAll()
        NowPlaying.shared.disposed(self)
    }

    private func rewind() {
        seeking += 1
        Task { @MainActor in
            await player.seek(to: .zero)
            seeking -= 1
            reportState()
        }
    }

    private func dropItem() {
        itemObservations.removeAll()
        itemTokens.forEach(NotificationCenter.default.removeObserver)
        itemTokens.removeAll()
    }

    private func controlChanged() {
        guard seeking == 0, player.timeControlStatus != control else { return }
        reportState()
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        if item.status == .failed {
            let message = item.error?.localizedDescription ?? "the item failed"
            print("audio: \(id) failed:", message)
            failed(message)
        } else if item.status == .readyToPlay {
            durationChanged(item)
        }
    }

    private func durationChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        // A live stream has an indefinite duration: stays 0.
        let seconds = item.duration.seconds
        let known = seconds.isFinite && seconds > 0 ? seconds : 0
        guard known != duration else { return }
        duration = known
        reportState()
    }

    private func ended() {
        post(["type": "ended", "id": id])
        status = .stopped
        rewind()
    }

    private func failed(_ message: String) {
        fail(message)
        player.pause()
        status = .stopped
        reportState()
    }
}

/// Now Playing (the menu bar / Control Center / lock screen) and the media keys, for the player
/// played last, whichever page it belongs to. play / pause / toggle act on it here; next and
/// previous are the page's (a `command` event to the player's page).
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private weak var current: AudioPlayer?
    private var registered = false

    func played(_ player: AudioPlayer) {
        current = player
        register()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("audio: the audio session:", error.localizedDescription)
        }
        #endif
    }

    func changed(_ player: AudioPlayer) {
        guard player === current else { return }
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.title ?? player.url.flatMap { URL(string: $0)?.lastPathComponent } ?? player.id,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
        ]
        if let artist = player.artist { info[MPMediaItemPropertyArtist] = artist }
        if player.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = player.url != nil && player.player.currentItem?.status == .readyToPlay
        }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = switch player.status {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
        #endif
    }

    func disposed(_ player: AudioPlayer) {
        guard player === current else { return }
        current = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func register() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        add(commands.playCommand) { $0.play() }
        add(commands.pauseCommand) { $0.pause() }
        add(commands.togglePlayPauseCommand) { $0.status == .playing ? $0.pause() : $0.play() }
        add(commands.nextTrackCommand) { $0.command("next") }
        add(commands.previousTrackCommand) { $0.command("previous") }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioPlayer) -> Void) {
        command.isEnabled = true
        command.addTarget { _ in
            MainActor.assumeIsolated {
                guard let player = NowPlaying.shared.current else { return .noActionableNowPlayingItem }
                action(player)
                return .success
            }
        }
    }
}
