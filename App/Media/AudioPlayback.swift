import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The music player: songs from a folder or playlist in a queue, shuffle and repeat, and the
/// Lock Screen and Control Center controls. Every window shows a mini player while it plays.
final class AudioPlayback: ObservableObject {
    nonisolated enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one

        var symbol: String {
            switch self {
            case .off, .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    @Published private(set) var queue: [URL] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: UIImage?
    @Published var shuffle = false {
        didSet { reorder() }
    }
    @Published var repeatMode: RepeatMode = .off

    private let player = AVPlayer()
    /// The order songs play in (indices into `queue`), shuffled or not.
    private var order: [Int] = []
    private var position = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var commandsReady = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    var current: URL? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var hasQueue: Bool {
        !queue.isEmpty
    }

    /// Plays `urls` starting with the song at `start`.
    func play(_ urls: [URL], startAt start: Int = 0) {
        guard !urls.isEmpty else { return }
        queue = urls
        order = Array(urls.indices)
        let first = min(max(start, 0), urls.count - 1)
        if shuffle {
            order = [first] + order.filter { $0 != first }.shuffled()
        }
        position = order.firstIndex(of: first) ?? 0
        AudioSessionController.activatePlayback()
        configureRemoteCommands()
        playCurrent()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard hasQueue else { return }
        if player.currentItem == nil {
            playCurrent()
        } else {
            player.play()
            isPlaying = true
            updateNowPlaying()
        }
    }

    func next() {
        if position + 1 < order.count {
            position += 1
            playCurrent()
        } else if repeatMode == .all {
            position = 0
            playCurrent()
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if elapsed > 3 || position == 0 {
            seek(to: 0)
        } else {
            position -= 1
            playCurrent()
        }
    }

    /// Jumps to a song in the queue.
    func select(_ queueIndex: Int) {
        guard let newPosition = order.firstIndex(of: queueIndex) else { return }
        position = newPosition
        playCurrent()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        elapsed = max(0, seconds)
        updateNowPlaying()
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    func stop() {
        player.replaceCurrentItem(with: nil)
        queue = []
        order = []
        isPlaying = false
        elapsed = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Internals

    private func reorder() {
        guard !queue.isEmpty else { return }
        let playing = index
        order = Array(queue.indices)
        if shuffle {
            order = [playing] + order.filter { $0 != playing }.shuffled()
        }
        position = order.firstIndex(of: playing) ?? 0
    }

    private func playCurrent() {
        guard order.indices.contains(position) else { return }
        index = order[position]
        let url = queue[index]
        let item = AVPlayerItem(url: url)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.songEnded() }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        elapsed = 0
        duration = 0
        title = url.deletingPathExtension().lastPathComponent
        artist = ""
        artwork = nil
        updateNowPlaying()
        Task { await loadMetadata(for: url) }
    }

    private func songEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    private func tick(_ time: CMTime) {
        guard player.currentItem != nil else { return }
        elapsed = time.seconds.isFinite ? time.seconds : 0
        if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds != duration {
            duration = seconds
            updateNowPlaying()
        }
    }

    private func loadMetadata(for url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata), current == url else { return }
        for item in metadata {
            switch item.commonKey {
            case .commonKeyTitle?:
                if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
            case .commonKeyArtist?:
                if let value = try? await item.load(.stringValue) { artist = value }
            case .commonKeyArtwork?:
                if let data = try? await item.load(.dataValue) { artwork = UIImage(data: data) }
            default:
                break
            }
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard hasQueue else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: seconds) }
            return .success
        }
    }
}
