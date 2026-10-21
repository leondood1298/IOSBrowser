import Combine
import UIKit

/// The row of tabs under the toolbar. Tabs share the width (within limits) and scroll when
/// there are many; drag a tab to reorder it.
final class TabStripView: UIView {
    var onSelect: ((TabModel) -> Void)?
    var onClose: ((TabModel) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onToggleMute: ((TabModel) -> Void)?
    var favicons: FaviconStore?

    private var tabs: [TabModel] = []
    private var selectedID: UUID?
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let minimumTabWidth: CGFloat = 140
    private let maximumTabWidth: CGFloat = 260

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.register(TabStripCell.self, forCellWithReuseIdentifier: TabStripCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.accessibilityIdentifier = "tabStrip"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(tabs: [TabModel], selectedID: UUID?) {
        let changedTabs = tabs.map(\.id) != self.tabs.map(\.id)
        self.tabs = tabs
        self.selectedID = selectedID
        if changedTabs {
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.reloadData()
        } else {
            for case let cell as TabStripCell in collectionView.visibleCells {
                if let id = cell.tabID { cell.isCurrent = id == selectedID }
            }
        }
        scrollToSelected()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func scrollToSelected() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
    }

    private func makeLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 1
        layout.sectionInset = .zero
        return layout
    }

    private func tabWidth() -> CGFloat {
        guard !tabs.isEmpty else { return maximumTabWidth }
        let available = bounds.width - CGFloat(tabs.count - 1)
        return min(maximumTabWidth, max(minimumTabWidth, available / CGFloat(tabs.count)))
    }
}

extension TabStripView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabStripCell.reuseID, for: indexPath)
        if let cell = cell as? TabStripCell {
            let tab = tabs[indexPath.item]
            cell.configure(with: tab, isCurrent: tab.id == selectedID, favicons: favicons)
            cell.onClose = { [weak self] in self?.onClose?(tab) }
            cell.onToggleMute = { [weak self] in self?.onToggleMute?(tab) }
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: tabWidth(), height: max(collectionView.bounds.height - 1, 1))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(tabs[indexPath.item])
    }
}

extension TabStripView: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        let tab = tabs[indexPath.item]
        let provider = tab.url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        let item = UIDragItem(itemProvider: provider)
        item.localObject = tab
        return [item]
    }

    func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let item = coordinator.items.first, let source = item.sourceIndexPath else { return }
        let destination = min(coordinator.destinationIndexPath?.item ?? tabs.count - 1, tabs.count - 1)
        onMove?(source.item, destination)
        coordinator.drop(item.dragItem, toItemAt: IndexPath(item: destination, section: 0))
    }
}

/// One tab in the strip: favicon placeholder, title and a close button.
final class TabStripCell: UICollectionViewCell {
    static let reuseID = "TabStripCell"

    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?
    private(set) var tabID: UUID?
    var isCurrent = false { didSet { updateAppearance() } }

    private let iconView = UIImageView(image: UIImage(systemName: "globe"))
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let audioButton = UIButton(type: .system)
    private var observers: Set<AnyCancellable> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        spinner.hidesWhenStopped = true
        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .caption2, scale: .small), forImageIn: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        audioButton.tintColor = .secondaryLabel
        audioButton.accessibilityIdentifier = "tabAudioButton"
        audioButton.isHidden = true
        audioButton.addAction(UIAction { [weak self] _ in self?.onToggleMute?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [closeButton, iconView, spinner, titleLabel, audioButton])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            audioButton.widthAnchor.constraint(equalToConstant: 24),
        ])
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        addInteraction(UIPointerInteraction(delegate: nil))
        closeButton.accessibilityIdentifier = "closeTabButton"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observers.removeAll()
        onClose = nil
        onToggleMute = nil
        tabID = nil
    }

    func configure(with tab: TabModel, isCurrent: Bool, favicons: FaviconStore?) {
        tabID = tab.id
        self.isCurrent = isCurrent
        observers.removeAll()
        let refreshIcon = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.iconView.image = favicons?.icon(for: tab.url) ?? UIImage(systemName: tab.isPrivate ? "hand.raised" : "globe")
        }
        refreshIcon()
        favicons?.$revision
            .receive(on: RunLoop.main)
            .sink { _ in refreshIcon() }
            .store(in: &observers)
        tab.$url
            .receive(on: RunLoop.main)
            .sink { _ in refreshIcon() }
            .store(in: &observers)
        tab.$isPlayingAudio.combineLatest(tab.$isMuted)
            .receive(on: RunLoop.main)
            .sink { [weak self] playing, muted in
                guard let self else { return }
                self.audioButton.isHidden = !(playing || muted)
                self.audioButton.setImage(UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal)
                self.audioButton.accessibilityLabel = muted ? "Unmute Tab" : "Mute Tab"
            }
            .store(in: &observers)
        tab.$pageTitle.combineLatest(tab.$url)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _ in
                guard let self, let tab else { return }
                self.titleLabel.text = tab.title
            }
            .store(in: &observers)
        tab.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in
                guard let self else { return }
                if loading { self.spinner.startAnimating() } else { self.spinner.stopAnimating() }
                self.iconView.isHidden = loading
            }
            .store(in: &observers)
    }

    private func updateAppearance() {
        contentView.backgroundColor = isCurrent ? .systemBackground : .clear
        titleLabel.textColor = isCurrent ? .label : .secondaryLabel
        closeButton.isHidden = !isCurrent
        titleLabel.accessibilityTraits = isCurrent ? [.selected] : []
    }
}
