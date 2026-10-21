import MobileVLCKit
import UIKit

/// Plays what the system player can't open (MKV, WebM, AVI, FLV, WMV, MPEG-TS, Ogg, WMA…) with
/// VLC. Tap to show or hide the controls; double-tap the left or right side to skip 10 seconds;
/// keys: Space, ← →, Esc. The folder's next file plays after this one, and each file continues
/// where it was left.
final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    /// File extensions VLC handles that the system player doesn't.
    static let extensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "f4v", "wmv", "asf", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv",
        "ogg", "oga", "opus", "wma", "ape", "divx", "xvid", "rm", "rmvb", "3gp", "3g2", "dv", "mxf",
    ]

    static func canPlay(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    private let urls: [URL]
    private var index: Int
    private let positions: PlaybackPositions
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let controls = PassthroughView()
    private let titleLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let hint = UILabel()
    private var hideTimer: Timer?
    private var restoredPosition = false
    private var isScrubbing = false

    init(urls: [URL], index: Int, positions: PlaybackPositions) {
        self.urls = urls
        self.index = min(max(index, 0), max(urls.count - 1, 0))
        self.positions = positions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "vlcPlayer"
        videoView.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        configureControls()
        configureGestures()
        player.delegate = self
        player.drawable = videoView
        AudioSessionController.activatePlayback()
        load(index)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        savePosition()
        hideTimer?.invalidate()
        player.stop()
    }

    // MARK: Playing

    private func load(_ newIndex: Int) {
        guard urls.indices.contains(newIndex) else { return }
        index = newIndex
        restoredPosition = false
        titleLabel.text = urls[newIndex].lastPathComponent
        player.media = VLCMedia(url: urls[newIndex])
        player.play()
        scheduleHide()
    }

    private func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        updatePlayButton()
        scheduleHide()
    }

    private func skip(by seconds: Int32) {
        if seconds > 0 {
            player.jumpForward(seconds)
        } else {
            player.jumpBackward(-seconds)
        }
        showHint(seconds > 0 ? "+\(seconds) s" : "−\(-seconds) s")
    }

    private func savePosition() {
        guard urls.indices.contains(index) else { return }
        let seconds = Double(player.time.intValue) / 1000
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length > 0, length - seconds < 10 {
            positions.clear(urls[index])
        } else if seconds > 5 {
            positions.save(seconds, for: urls[index])
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        updatePlayButton()
        switch player.state {
        case .playing:
            if !restoredPosition {
                restoredPosition = true
                if let seconds = positions.position(for: urls[index]), seconds > 5 {
                    player.time = VLCTime(int: Int32(seconds * 1000))
                }
            }
        case .ended:
            positions.clear(urls[index])
            if index + 1 < urls.count {
                load(index + 1)
            } else {
                showControls()
            }
        case .error:
            showHint("This file can't be played")
            showControls()
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard !isScrubbing else { return }
        let length = player.media?.length.intValue ?? 0
        slider.value = length > 0 ? Float(player.time.intValue) / Float(length) : 0
        timeLabel.text = "\(player.time.stringValue) / \(player.media?.length.stringValue ?? "--:--")"
    }

    // MARK: Controls

    private func configureControls() {
        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controls)

        let top = UIStackView()
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "Done"
        close.accessibilityIdentifier = "vlcDoneButton"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let tracks = UIButton(type: .system)
        tracks.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        tracks.accessibilityLabel = "Audio and Subtitles"
        tracks.showsMenuAsPrimaryAction = true
        tracks.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.trackMenus() ?? [])
        }])
        let speed = UIButton(type: .system)
        speed.setImage(UIImage(systemName: "gauge.with.dots.needle.67percent"), for: .normal)
        speed.accessibilityLabel = "Speed"
        speed.showsMenuAsPrimaryAction = true
        speed.menu = UIMenu(title: "Speed", children: [0.5, 1, 1.25, 1.5, 2].map { rate in
            UIAction(title: rate == 1 ? "Normal" : String(format: "%g×", rate)) { [weak self] _ in self?.player.rate = Float(rate) }
        })
        for view in [close, titleLabel, UIView(), speed, tracks] as [UIView] {
            top.addArrangedSubview(view)
        }
        top.spacing = 20
        top.alignment = .center

        playButton.accessibilityIdentifier = "vlcPlayPause"
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        playButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 28), forImageIn: .normal)
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        back.accessibilityLabel = "Back 10 Seconds"
        back.addAction(UIAction { [weak self] _ in self?.skip(by: -10) }, for: .touchUpInside)
        let forward = UIButton(type: .system)
        forward.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        forward.accessibilityLabel = "Forward 10 Seconds"
        forward.addAction(UIAction { [weak self] _ in self?.skip(by: 10) }, for: .touchUpInside)
        slider.addAction(UIAction { [weak self] _ in self?.isScrubbing = true }, for: .touchDown)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.player.position = self.slider.value
            self.isScrubbing = false
            self.scheduleHide()
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        timeLabel.text = "0:00 / --:--"
        timeLabel.accessibilityIdentifier = "vlcTime"
        let bottom = UIStackView(arrangedSubviews: [back, playButton, forward, slider, timeLabel])
        bottom.spacing = 18
        bottom.alignment = .center

        for bar in [top, bottom] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.isLayoutMarginsRelativeArrangement = true
            bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
            bar.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            bar.layer.cornerRadius = 18
            bar.tintColor = .white
            controls.addSubview(bar)
        }
        hint.font = .preferredFont(forTextStyle: .headline)
        hint.textColor = .white
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hint.layer.cornerRadius = 12
        hint.layer.masksToBounds = true
        hint.textAlignment = .center
        hint.alpha = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            hint.heightAnchor.constraint(equalToConstant: 44),
            hint.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        updatePlayButton()
    }

    private func updatePlayButton() {
        let playing = player.isPlaying
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = playing ? "Pause" : "Play"
    }

    /// Audio and subtitle tracks to choose from, when the file has more than one.
    private func trackMenus() -> [UIMenuElement] {
        func menu(title: String, names: [Any], indexes: [Any], current: Int32, select: @escaping (Int32) -> Void) -> UIMenu {
            let actions = zip(names, indexes).compactMap { name, index -> UIAction? in
                guard let name = name as? String, let index = (index as? NSNumber)?.int32Value else { return nil }
                return UIAction(title: name, state: index == current ? .on : .off) { _ in select(index) }
            }
            return UIMenu(title: title, options: .displayInline, children: actions)
        }
        let audio = menu(
            title: "Audio", names: player.audioTrackNames, indexes: player.audioTrackIndexes,
            current: player.currentAudioTrackIndex) { [weak self] in self?.player.currentAudioTrackIndex = $0 }
        let subtitles = menu(
            title: "Subtitles", names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes,
            current: player.currentVideoSubTitleIndex) { [weak self] in self?.player.currentVideoSubTitleIndex = $0 }
        return [audio, subtitles]
    }

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        videoView.addGestureRecognizer(tap)
        videoView.addGestureRecognizer(doubleTap)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if controls.alpha > 0 {
            hideControls()
        } else {
            showControls()
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: view).x
        let third = view.bounds.width / 3
        if x < third {
            skip(by: -10)
        } else if x > third * 2 {
            skip(by: 10)
        } else {
            togglePlay()
        }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        scheduleHide()
    }

    private func hideControls() {
        hideTimer?.invalidate()
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 0 }
    }

    /// Controls hide after a few seconds of playing.
    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.isPlaying, !self.isScrubbing else { return }
                self.hideControls()
            }
        }
    }

    private func showHint(_ text: String) {
        hint.text = "  \(text)  "
        hint.alpha = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            UIView.animate(withDuration: 0.2) { self?.hint.alpha = 0 }
        }
    }

    // MARK: Keys

    override var keyCommands: [UIKeyCommand]? {
        let space = UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyPlay))
        let left = UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyBack))
        let right = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyForward))
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyClose))
        for command in [space, left, right, escape] {
            command.wantsPriorityOverSystemBehavior = true
        }
        return [space, left, right, escape]
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @objc private func keyPlay() { togglePlay() }
    @objc private func keyBack() { skip(by: -10) }
    @objc private func keyForward() { skip(by: 10) }
    @objc private func keyClose() { dismiss(animated: true) }
}

/// Takes touches only on its subviews (the control bars), so taps elsewhere reach the video.
private final class PassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.alpha > 0.01 && $0.frame.contains(point) }
    }
}
