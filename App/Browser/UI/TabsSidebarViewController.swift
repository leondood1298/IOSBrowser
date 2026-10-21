import Combine
import UIKit

/// The window's sidebar. For now it lists the window's tabs and private tabs; later milestones
/// add tab groups, bookmarks, history, downloads and files.
final class TabsSidebarViewController: UIViewController {
    private enum Section: Int, CaseIterable {
        case tabs
        case privateTabs

        var title: String {
            switch self {
            case .tabs: return "Tabs"
            case .privateTabs: return "Private Tabs"
            }
        }
    }

    private let model: BrowserWindowModel
    private var observers: Set<AnyCancellable> = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, UUID>!

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

        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let tab = self?.model.allTabs.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.sidebarCell()
            content.text = tab.title
            content.image = UIImage(systemName: tab.isPrivate ? "hand.raised" : "globe")
            cell.contentConfiguration = content
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section)?.title
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        model.normalGroup.$tabs.combineLatest(model.privateGroup.$tabs, model.$selectedTab)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.reload() }
            .store(in: &observers)
    }

    private func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        snapshot.appendSections([.tabs])
        snapshot.appendItems(model.normalGroup.tabs.map(\.id), toSection: .tabs)
        if !model.privateGroup.tabs.isEmpty {
            snapshot.appendSections([.privateTabs])
            snapshot.appendItems(model.privateGroup.tabs.map(\.id), toSection: .privateTabs)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        if let selected = model.selectedTab, let indexPath = dataSource.indexPath(for: selected.id) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func tab(at indexPath: IndexPath) -> TabModel? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return model.allTabs.first { $0.id == id }
    }
}

extension TabsSidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tab = tab(at: indexPath) else { return }
        model.select(tab)
    }
}
