import QuickLookThumbnailing
import UIKit

/// One page of the image viewer: pinch to zoom, double-tap to zoom in or out.
final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "viewerImage"
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var image: UIImage? {
        get { imageView.image }
        set {
            setZoomScale(1, animated: false)
            imageView.image = newValue
            fitImage()
        }
    }

    var isZoomed: Bool {
        zoomScale > minimumZoomScale + 0.01
    }

    private var lastBounds = CGRect.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds.size {
            lastBounds = bounds
            setZoomScale(1, animated: false)
            fitImage()
        }
        centerImage()
    }

    /// Sizes the image to fit the screen; zooming then scales from there.
    private func fitImage() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            imageView.frame = bounds
            contentSize = bounds.size
            return
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerImage()
    }

    private func centerImage() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(x: contentSize.width / 2 + x, y: contentSize.height / 2 + y)
    }

    func toggleZoom(at point: CGPoint) {
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let location = imageView.convert(point, from: self)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: location.x - size.width / 2, y: location.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }
}

/// The image viewer: every image in a folder, one at a time. Next and previous are instant (no
/// slide) by default: tap the left or right edge, the ‹ › buttons, swipe in any direction, or use
/// the arrow keys, space and Page Up/Down. A thumbnail strip jumps anywhere.
final class ImageViewerController: UIViewController, UIGestureRecognizerDelegate {
    private var urls: [URL]
    private var index: Int
    private let files: FileStore
    private let preferences: Preferences
    private let loader: ImageLoader
    private let page = ZoomingImageView()
    private let counter = UILabel()
    private let topBar = UIView()
    private let bottomBar = UIView()
    private lazy var strip = UICollectionView(frame: .zero, collectionViewLayout: makeStripLayout())
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let slideshowButton = UIButton(type: .system)
    private var slideshow: Timer?
    private var chromeHidden = false
    private var loadTask: Task<Void, Never>?

    init(urls: [URL], index: Int, files: FileStore, preferences: Preferences) {
        self.urls = urls
        self.index = min(max(index, 0), max(urls.count - 1, 0))
        self.files = files
        self.preferences = preferences
        let screen = UIScreen.main
        loader = ImageLoader(maxPixelSize: max(screen.bounds.width, screen.bounds.height) * screen.scale * 1.5)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        page.frame = view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page)
        configureBars()
        configureGestures()
        show(index, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSlideshow()
    }

    // MARK: Layout

    private func configureBars() {
        for bar in [topBar, bottomBar] {
            bar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
        }
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.accessibilityIdentifier = "viewerDoneButton"
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        counter.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        counter.textColor = .white
        counter.textAlignment = .center
        counter.accessibilityIdentifier = "viewerCounter"

        let share = iconButton("square.and.arrow.up", label: "Share") { [weak self] in self?.shareCurrent() }
        let delete = iconButton("trash", label: "Delete") { [weak self] in self?.deleteCurrent() }
        configure(slideshowButton, symbol: "play.fill", label: "Slideshow") { [weak self] in self?.toggleSlideshow() }
        let trailing = UIStackView(arrangedSubviews: [slideshowButton, share, delete])
        trailing.spacing = 22

        for item in [done, counter, trailing] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }

        configure(previousButton, symbol: "chevron.left", label: "Previous") { [weak self] in self?.step(-1) }
        configure(nextButton, symbol: "chevron.right", label: "Next") { [weak self] in self?.step(1) }
        previousButton.accessibilityIdentifier = "viewerPrevious"
        nextButton.accessibilityIdentifier = "viewerNext"
        strip.backgroundColor = .clear
        strip.showsHorizontalScrollIndicator = false
        strip.dataSource = self
        strip.delegate = self
        strip.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuseID)
        for item in [previousButton, strip, nextButton] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(item)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: 52),
            done.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            done.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -10),
            counter.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            counter.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            trailing.centerYAnchor.constraint(equalTo: done.centerYAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -84),
            previousButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            previousButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 10),
            previousButton.widthAnchor.constraint(equalToConstant: 52),
            previousButton.heightAnchor.constraint(equalToConstant: 64),
            nextButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            nextButton.topAnchor.constraint(equalTo: previousButton.topAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 52),
            nextButton.heightAnchor.constraint(equalToConstant: 64),
            strip.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor, constant: 8),
            strip.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),
            strip.topAnchor.constraint(equalTo: previousButton.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: 64),
        ])
    }

    private func makeStripLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 56, height: 56)
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return layout
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, symbol: symbol, label: label, action: action)
        return button
    }

    private func configure(_ button: UIButton, symbol: String, label: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    // MARK: Gestures and keys

    private func configureGestures() {
        // Single taps don't wait to see whether a double tap follows, so edge taps turn the
        // page at once.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        page.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        page.addGestureRecognizer(doubleTap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            page.addGestureRecognizer(swipe)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Swipes turn pages only when the image isn't zoomed in (then they pan it).
        !(gestureRecognizer is UISwipeGestureRecognizer && page.isZoomed)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: view).x
        let edge = view.bounds.width * 0.22
        if x < edge {
            step(-1)
        } else if x > view.bounds.width - edge {
            step(1)
        } else {
            setChromeHidden(!chromeHidden)
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: view).x
        let edge = view.bounds.width * 0.22
        guard x >= edge, x <= view.bounds.width - edge else { return }
        page.toggleZoom(at: recognizer.location(in: page))
    }

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        switch recognizer.direction {
        case .left, .up: step(1)
        default: step(-1)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let next = [UIKeyCommand.inputRightArrow, UIKeyCommand.inputDownArrow, " ", UIKeyCommand.inputPageDown]
        let previous = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageUp]
        var commands = next.map { input in
            UIKeyCommand(title: "Next", action: #selector(nextKey), input: input)
        }
        commands += previous.map { input in
            UIKeyCommand(title: "Previous", action: #selector(previousKey), input: input)
        }
        commands.append(UIKeyCommand(title: "Close", action: #selector(closeKey), input: UIKeyCommand.inputEscape))
        commands.append(UIKeyCommand(title: "Close", action: #selector(closeKey), input: "w", modifierFlags: .command))
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
    }

    @objc private func nextKey() { step(1) }
    @objc private func previousKey() { step(-1) }
    @objc private func closeKey() { dismiss(animated: true) }

    // MARK: Paging

    private func step(_ delta: Int) {
        guard !urls.isEmpty else { return }
        let target = index + delta
        guard urls.indices.contains(target) else { return }
        show(target, animated: preferences.viewerTransition == .slide, forward: delta > 0)
    }

    private func show(_ newIndex: Int, animated: Bool, forward: Bool = true) {
        guard urls.indices.contains(newIndex) else { return }
        index = newIndex
        counter.text = "\(index + 1) / \(urls.count)"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < urls.count - 1
        let url = urls[index]
        loadTask?.cancel()
        if let image = loader.cached(url) {
            display(image, animated: animated, forward: forward)
        } else {
            loadTask = Task { [weak self] in
                guard let self else { return }
                let image = await self.loader.image(for: url)
                guard !Task.isCancelled, self.index == newIndex else { return }
                self.display(image, animated: animated, forward: forward)
            }
        }
        loader.preload(around: index, in: urls)
        strip.reloadData()
        strip.layoutIfNeeded()
        if strip.numberOfItems(inSection: 0) > index {
            strip.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
        }
    }

    private func display(_ image: UIImage?, animated: Bool, forward: Bool) {
        if animated {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = forward ? .fromRight : .fromLeft
            transition.duration = 0.22
            page.layer.add(transition, forKey: "page")
        }
        page.image = image
        page.imageView.accessibilityLabel = urls.indices.contains(index) ? urls[index].lastPathComponent : nil
    }

    private func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = hidden ? 0 : 1
            self.bottomBar.alpha = hidden ? 0 : 1
            self.setNeedsStatusBarAppearanceUpdate()
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    // MARK: Actions

    private func toggleSlideshow() {
        if slideshow != nil {
            stopSlideshow()
            return
        }
        setChromeHidden(true)
        let interval = max(preferences.slideshowInterval, 1)
        slideshow = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.show(self.index + 1 < self.urls.count ? self.index + 1 : 0, animated: self.preferences.viewerTransition == .slide)
            }
        }
        slideshowButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        slideshowButton.accessibilityLabel = "Pause Slideshow"
    }

    private func stopSlideshow() {
        slideshow?.invalidate()
        slideshow = nil
        slideshowButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        slideshowButton.accessibilityLabel = "Slideshow"
    }

    private func shareCurrent() {
        guard urls.indices.contains(index) else { return }
        let controller = UIActivityViewController(activityItems: [urls[index]], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = topBar
            popover.sourceRect = CGRect(x: topBar.bounds.maxX - 80, y: topBar.bounds.maxY - 26, width: 1, height: 1)
        }
        present(controller, animated: true)
    }

    private func deleteCurrent() {
        guard urls.indices.contains(index) else { return }
        let url = urls[index]
        let trash = preferences.useTrash
        let alert = UIAlertController(
            title: "Delete “\(url.lastPathComponent)”?",
            message: trash ? "It stays in the Trash for 30 days." : "This can't be undone.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.files.delete([url])
            } catch {
                return
            }
            self.urls.remove(at: self.index)
            if self.urls.isEmpty {
                self.dismiss(animated: true)
            } else {
                self.show(min(self.index, self.urls.count - 1), animated: false)
            }
        })
        present(alert, animated: true)
    }
}

extension ImageViewerController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbnailCell.reuseID, for: indexPath)
        if let cell = cell as? ThumbnailCell {
            cell.configure(url: urls[indexPath.item], selected: indexPath.item == index, scale: traitCollection.displayScale)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        show(indexPath.item, animated: false)
    }
}

/// A small thumbnail in the viewer's strip.
final class ThumbnailCell: UICollectionViewCell {
    static let reuseID = "ThumbnailCell"
    private let imageView = UIImageView()
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 6
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        contentView.layer.cornerRadius = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(url: URL, selected: Bool, scale: CGFloat) {
        contentView.layer.borderWidth = selected ? 2.5 : 0
        contentView.layer.borderColor = UIColor.white.cgColor
        imageView.alpha = selected ? 1 : 0.7
        guard self.url != url else { return }
        self.url = url
        imageView.image = nil
        Task { [weak self] in
            let image = await Thumbnails.shared.image(for: url, size: 56, scale: scale)
            guard let self, self.url == url else { return }
            self.imageView.image = image
        }
    }
}
