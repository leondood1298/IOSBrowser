import Combine
import UIKit

/// A grid of the window's tabs with snapshots. Switch between normal and private tabs,
/// open a tab, close tabs or start a new one.
final class TabOverviewViewController: UIViewController {
    private let model: BrowserWindowModel
    private var showingPrivate: Bool
    private var observers: Set<AnyCancellable> = []
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let modeControl = UISegmentedControl(items: ["Tabs", "Private"])

    init(model: BrowserWindowModel) {
        self.model = model
        showingPrivate = model.isPrivate
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var tabs: [TabModel] {
        showingPrivate ? model.privateGroup.tabs : model.normalGroup.tabs
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.isOpaque = true

        modeControl.selectedSegmentIndex = showingPrivate ? 1 : 0
        modeControl.accessibilityIdentifier = "tabModeControl"
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)

        let navigationBar = UINavigationBar()
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        let item = UINavigationItem()
        item.titleView = modeControl
        let newTab = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.addTab() })
        newTab.accessibilityIdentifier = "overviewNewTabButton"
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismissOverview() })
        done.accessibilityIdentifier = "overviewDoneButton"
        let closeAll = UIBarButtonItem(title: "Close All", primaryAction: UIAction { [weak self] _ in self?.closeAll() })
        item.leftBarButtonItems = [closeAll]
        item.rightBarButtonItems = [done, newTab]
        navigationBar.setItems([item], animated: false)
        view.addSubview(navigationBar)

        collectionView.backgroundColor = .clear
        collectionView.register(TabCardCell.self, forCellWithReuseIdentifier: TabCardCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "tabOverview"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        model.normalGroup.$tabs.merge(with: model.privateGroup.$tabs)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.collectionView.reloadData() }
            .store(in: &observers)
        applyMode()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(2, Int(width / 260))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(width / CGFloat(columns) * 0.95)),
                repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 24, trailing: 16)
            return section
        }
    }

    private func modeChanged() {
        showingPrivate = modeControl.selectedSegmentIndex == 1
        applyMode()
    }

    private func applyMode() {
        overrideUserInterfaceStyle = showingPrivate ? .dark : .unspecified
        collectionView.reloadData()
    }

    private func addTab() {
        model.newTab(isPrivate: showingPrivate)
        dismissOverview()
    }

    private func closeAll() {
        model.closeAllTabs(isPrivate: showingPrivate)
        if showingPrivate {
            dismissOverview()
        }
    }

    private func dismissOverview() {
        if showingPrivate != model.isPrivate {
            model.setPrivate(showingPrivate)
        }
        dismiss(animated: true)
    }
}

extension TabOverviewViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabCardCell.reuseID, for: indexPath)
        if let cell = cell as? TabCardCell {
            let tab = tabs[indexPath.item]
            cell.configure(with: tab, isCurrent: tab === model.selectedTab)
            cell.onClose = { [weak self] in
                self?.model.close(tab)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        model.select(tabs[indexPath.item])
        dismiss(animated: true)
    }
}

/// A tab in the overview: snapshot, title and close button.
final class TabCardCell: UICollectionViewCell {
    static let reuseID = "TabCardCell"
    var onClose: (() -> Void)?

    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var observers: Set<AnyCancellable> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.layer.borderColor = UIColor.tintColor.cgColor

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .tertiarySystemFill
        imageView.tintColor = .tertiaryLabel
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.accessibilityIdentifier = "closeCardButton"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.spacing = 6
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 6)
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let stack = UIStackView(arrangedSubviews: [header, imageView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observers.removeAll()
        onClose = nil
    }

    func configure(with tab: TabModel, isCurrent: Bool) {
        contentView.layer.borderWidth = isCurrent ? 3 : 0
        observers.removeAll()
        tab.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] image in
                guard let self else { return }
                if let image {
                    self.imageView.image = image
                    self.imageView.contentMode = .scaleAspectFill
                } else {
                    self.imageView.image = UIImage(systemName: tab?.showsStartPage == true ? "plus" : "globe")
                    self.imageView.contentMode = .center
                }
            }
            .store(in: &observers)
        tab.$pageTitle.combineLatest(tab.$url)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _ in
                self?.titleLabel.text = tab?.title
            }
            .store(in: &observers)
    }
}
