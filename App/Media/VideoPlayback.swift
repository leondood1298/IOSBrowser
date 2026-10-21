import AVFoundation
import AVKit
import UIKit

/// Plays videos from the file manager in the system player (picture in picture, AirPlay,
/// speeds, audio and subtitle tracks). On top: double-tap the left or right side to skip 10
/// seconds, hold the right side to play at 2×, and the folder's next video plays after this one.
/// Each video continues where it was left. The session stays alive during picture in picture.
final class VideoPlayback: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    /// The playing session; kept while the player is open or in picture in picture.
    private static var current: VideoPlayback?

    let controller = AVPlayerViewController()
    private let urls: [URL]
    /// For videos from a page: its cookies and user agent.
    private let assetOptions: [String: Any]
    private let positions: PlaybackPositions
    private let queue = AVQueuePlayer()
    private var timeObserver: Any?
    private var endObservers: [NSObjectProtocol] = []
    private var rateBeforeHold: Float = 1
    private let hint = UILabel()
    private var inPictureInPicture = false

    init(
        urls: [URL], index: Int, preferences: Preferences, positions: PlaybackPositions, assetOptions: [String: Any] = [:]
    ) {
        self.urls = urls
        self.assetOptions = assetOptions
        self.positions = positions
        super.init()
        controller.player = queue
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.speeds = ([0.5, 1, 1.25, 1.5, 2] as [Float]).map { rate in
            AVPlaybackSpeed(rate: rate, localizedName: rate == 1 ? "Normal" : "\(rate)×")
        }
        controller.modalPresentationStyle = .fullScreen
        controller.view.accessibilityIdentifier = "videoPlayer"
        queue.audiovisualBackgroundPlaybackPolicy = preferences.backgroundPlayback ? .continuesIfPossible : .pauses
        configureGestures()
        configureHint()
        load(from: min(max(index, 0), max(urls.count - 1, 0)))
    }

    /// Opens the player full screen and starts playing.
    func present(from presenter: UIViewController) {
        Self.current?.stop()
        Self.current = self
        AudioSessionController.activatePlayback()
        presenter.present(controller, animated: true) { [weak self] in
            self?.queue.play()
        }
    }

    private func stop() {
        saveCurrentPosition()
        queue.pause()
        if let timeObserver {
            queue.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers.removeAll()
        if Self.current === self {
            Self.current = nil
        }
    }

    /// Queues the videos from `start` on.
    private func load(from start: Int) {
        for url in urls[start...] {
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions))
            queue.insert(item, after: nil)
            endObservers.append(NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finished(url) }
            })
        }
        restorePosition(for: urls[start])
        timeObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCurrentPosition() }
        }
    }

    private func currentURL() -> URL? {
        (queue.currentItem?.asset as? AVURLAsset)?.url
    }

    private func finished(_ url: URL) {
        positions.clear(url)
        // The queue moves to the next video by itself; start it where it was left.
        if let next = urls.firstIndex(of: url).map({ $0 + 1 }), urls.indices.contains(next) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restorePosition(for: self.urls[next])
            }
        }
    }

    private func restorePosition(for url: URL) {
        guard let seconds = positions.position(for: url), seconds > 5,
              let item = queue.items().first(where: { ($0.asset as? AVURLAsset)?.url == url })
        else { return }
        item.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), completionHandler: nil)
    }

    private func saveCurrentPosition() {
        guard let url = currentURL(), let item = queue.currentItem else { return }
        let seconds = item.currentTime().seconds
        let duration = item.duration.seconds
        guard seconds.isFinite else { return }
        if duration.isFinite, duration - seconds < 10 {
            positions.clear(url)
        } else {
            positions.save(seconds, for: url)
        }
    }

    // MARK: AVPlayerViewControllerDelegate

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !context.isCancelled, !self.inPictureInPicture else { return }
            self.stop()
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
        if controller.presentingViewController == nil {
            stop()
        }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard controller.presentingViewController == nil, let top = Self.topViewController() else {
            completionHandler(true)
            return
        }
        top.present(controller, animated: true) {
            completionHandler(true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: Gestures

    private func configureGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        controller.view.addGestureRecognizer(doubleTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.4
        hold.delegate = self
        controller.view.addGestureRecognizer(hold)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        let view = controller.view!
        let x = recognizer.location(in: view).x
        let third = view.bounds.width / 3
        if x < third {
            skip(by: -10)
        } else if x > third * 2 {
            skip(by: 10)
        }
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let view = controller.view!
        switch recognizer.state {
        case .began where recognizer.location(in: view).x > view.bounds.width / 2:
            rateBeforeHold = queue.rate == 0 ? 1 : queue.rate
            queue.rate = 2
            showHint("2×  ▶▶")
        case .ended, .cancelled, .failed:
            if queue.rate == 2 {
                queue.rate = rateBeforeHold
                hideHint()
            }
        default:
            break
        }
    }

    private func skip(by seconds: Double) {
        guard let item = queue.currentItem else { return }
        var target = item.currentTime().seconds + seconds
        if item.duration.seconds.isFinite {
            target = min(target, item.duration.seconds - 0.5)
        }
        queue.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
        showHint(seconds > 0 ? "+\(Int(seconds)) s" : "−\(Int(-seconds)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.hideHint() }
    }

    private func configureHint() {
        hint.font = .preferredFont(forTextStyle: .headline)
        hint.textColor = .white
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hint.layer.cornerRadius = 12
        hint.layer.masksToBounds = true
        hint.textAlignment = .center
        hint.alpha = 0
        guard let overlay = controller.contentOverlayView else { return }
        hint.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            hint.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 70),
            hint.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            hint.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func showHint(_ text: String) {
        hint.text = "  \(text)  "
        hint.alpha = 1
    }

    private func hideHint() {
        UIView.animate(withDuration: 0.2) { self.hint.alpha = 0 }
    }
}

/// Where each video or song was left, by path under Documents.
final class PlaybackPositions {
    private let defaults: UserDefaults
    private let key = "playbackPositions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func path(_ url: URL) -> String {
        AppServices.shared.files.relativePath(of: url)
    }

    func position(for url: URL) -> Double? {
        (defaults.dictionary(forKey: key) as? [String: Double])?[path(url)]
    }

    func save(_ seconds: Double, for url: URL) {
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[path(url)] = seconds
        defaults.set(all, forKey: key)
    }

    func clear(_ url: URL) {
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[path(url)] = nil
        defaults.set(all, forKey: key)
    }
}

/// The audio session: playback (sound continues in the background and with the ringer off),
/// set only once a player starts, so browsing doesn't interrupt other apps' audio.
enum AudioSessionController {
    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }
}
