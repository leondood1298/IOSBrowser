import Combine
import UIKit

/// The window's sidebar: library lists, the window's tabs and its private tabs. Later
/// milestones add tab groups, downloads and files.
final class TabsSidebarViewController: UIViewController {
    nonisolated private enum Section: Int, CaseIterable {
        case library
        case tabs
        case privateTabs

        var title: String {
            switch self {
            case .library: return "Library"
            case .tabs: return "Tabs"
            case .privateTabs: return "Private Tabs"
            }
        }
    }

    nonisolated private enum Item: Hashable {
        case library(LibraryItem)
        case tab(UUID)
    }

    nonisolated private enum LibraryItem: Hashable {
        case bookmarks
        case history

        var title: String { self == .bookmarks ? "Bookmarks" : "History" }
        var symbol: String { self == .bookmarks ? "book" : "clock" }
        var section: LibrarySection { self == .bookmarks ? .bookmarks : .history }
    }

    var onShowLibrary: ((LibrarySection) -> Void)?

    private let model: BrowserWindowModel
    private var observers: Set<AnyCancellable> = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(model: BrowserWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "Browser"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.headerMode = .supplementary
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let tab = self.tab(at: indexPath) else { return nil }
            let close = UIContextualAction(style: .destructive, title: "Close") { _, _, done in
                self.model.close(tab)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [close])
        }
        collectionView = UICollectionView(
            frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "sidebar"
        view.addSubview(collectionView)

        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.sidebarCell()
            switch item {
            case .library(let library):
                content.text = library.title
                content.image = UIImage(systemName: library.symbol)
                cell.accessories = [.disclosureIndicator()]
            case .tab(let id):
                guard let tab = self?.model.allTabs.first(where: { $0.id == id }) else { return }
                content.text = tab.title
                content.image = self?.model.services.favicons.icon(for: tab.url)
                    ?? UIImage(systemName: tab.isPrivate ? "hand.raised" : "globe")
                content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
                cell.accessories = tab.isPlayingAudio ? [.customView(configuration: .init(
                    customView: UIImageView(image: UIImage(systemName: tab.isMuted ? "speaker.slash" : "speaker.wave.2")),
                    placement: .trailing()))] : []
            }
            cell.contentConfiguration = content
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section)?.title
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        model.normalGroup.$tabs.combineLatest(model.privateGroup.$tabs, model.$selectedTab)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.reload() }
            .store(in: &observers)
        model.services.favicons.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &observers)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.library, .tabs])
        snapshot.appendItems([.library(.bookmarks), .library(.history)], toSection: .library)
        snapshot.appendItems(model.normalGroup.tabs.map { .tab($0.id) }, toSection: .tabs)
        if !model.privateGroup.tabs.isEmpty {
            snapshot.appendSections([.privateTabs])
            snapshot.appendItems(model.privateGroup.tabs.map { .tab($0.id) }, toSection: .privateTabs)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        if let selected = model.selectedTab, let indexPath = dataSource.indexPath(for: .tab(selected.id)) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func tab(at indexPath: IndexPath) -> TabModel? {
        guard case .tab(let id)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return model.allTabs.first { $0.id == id }
    }
}

extension TabsSidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .library(let library)?:
            collectionView.deselectItem(at: indexPath, animated: true)
            onShowLibrary?(library.section)
        case .tab(let id)?:
            if let tab = model.allTabs.first(where: { $0.id == id }) {
                model.select(tab)
            }
        case nil:
            break
        }
    }
}
