import Combine
import UIKit

/// The window's sidebar: library lists, tab groups, the shown group's tabs and private tabs.
/// Later milestones add downloads and files.
final class TabsSidebarViewController: UIViewController {
    nonisolated private enum Section: Int, CaseIterable {
        case library
        case groups
        case tabs
        case privateTabs

        var title: String {
            switch self {
            case .library: return "Library"
            case .groups: return "Tab Groups"
            case .tabs: return "Tabs"
            case .privateTabs: return "Private Tabs"
            }
        }
    }

    nonisolated private enum Item: Hashable {
        case library(LibraryItem)
        case group(UUID)
        case newGroup
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

    private var store: TabStore { model.services.tabStore }

    /// The window's own group, then the named groups.
    private var groups: [TabGroup] {
        [model.defaultGroup] + store.namedGroups
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
            guard let self else { return }
            var content = UIListContentConfiguration.sidebarCell()
            cell.accessories = []
            switch item {
            case .library(let library):
                content.text = library.title
                content.image = UIImage(systemName: library.symbol)
                cell.accessories = [.disclosureIndicator()]
            case .group(let id):
                guard let group = self.groups.first(where: { $0.id == id }) else { return }
                content.text = self.name(of: group)
                content.image = UIImage(systemName: group.title == nil ? "square.on.square" : "folder")
                if group === self.model.normalGroup {
                    cell.accessories = [.checkmark()]
                }
            case .newGroup:
                content.text = "New Tab Group"
                content.image = UIImage(systemName: "plus")
                content.textProperties.color = .tintColor
            case .tab(let id):
                guard let tab = self.model.allTabs.first(where: { $0.id == id }) else { return }
                content.text = tab.title
                content.image = self.model.services.favicons.icon(for: tab.url)
                    ?? UIImage(systemName: tab.isPrivate ? "hand.raised" : "globe")
                content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
                if tab.isPlayingAudio {
                    let icon = UIImageView(image: UIImage(systemName: tab.isMuted ? "speaker.slash" : "speaker.wave.2"))
                    cell.accessories = [.customView(configuration: .init(customView: icon, placement: .trailing()))]
                }
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

        model.$normalTabs.combineLatest(model.$privateTabs, model.$selectedTab)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.reload() }
            .store(in: &observers)
        model.$normalGroup
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &observers)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
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

    private func name(of group: TabGroup) -> String {
        if let title = group.title {
            return title
        }
        let count = group.tabs.count
        return count == 1 ? "1 Tab" : "\(count) Tabs"
    }

    private func reload() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.library, .groups, .tabs])
        snapshot.appendItems([.library(.bookmarks), .library(.history)], toSection: .library)
        snapshot.appendItems(groups.map { .group($0.id) } + [.newGroup], toSection: .groups)
        snapshot.appendItems(model.normalTabs.map { .tab($0.id) }, toSection: .tabs)
        if !model.privateTabs.isEmpty {
            snapshot.appendSections([.privateTabs])
            snapshot.appendItems(model.privateTabs.map { .tab($0.id) }, toSection: .privateTabs)
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

    private func group(at indexPath: IndexPath) -> TabGroup? {
        guard case .group(let id)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return groups.first { $0.id == id }
    }

    /// Asks for a tab group name, then calls `completion` with it.
    private func askForName(title: String, initial: String, action: String, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.placeholder = "Name"
            field.autocapitalizationType = .words
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let confirm = UIAlertAction(title: action, style: .default) { _ in
            completion(alert.textFields?.first?.text ?? "")
        }
        alert.addAction(confirm)
        alert.preferredAction = confirm
        present(alert, animated: true)
    }

    private func confirmDelete(_ group: TabGroup) {
        let count = group.tabs.count
        let alert = UIAlertController(
            title: "Delete \"\(name(of: group))\"?",
            message: count == 0 ? nil : "Its \(count == 1 ? "tab" : "\(count) tabs") will be closed.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.model.delete(group)
        })
        present(alert, animated: true)
    }
}

extension TabsSidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .library(let library)?:
            collectionView.deselectItem(at: indexPath, animated: true)
            onShowLibrary?(library.section)
        case .group?:
            collectionView.deselectItem(at: indexPath, animated: true)
            if let group = group(at: indexPath) {
                model.show(group)
            }
        case .newGroup?:
            collectionView.deselectItem(at: indexPath, animated: true)
            askForName(title: "New Tab Group", initial: "", action: "Create") { [weak self] name in
                self?.model.makeGroup(named: name, movingCurrentTabs: false)
            }
        case .tab(let id)?:
            if let tab = model.allTabs.first(where: { $0.id == id }) {
                model.select(tab)
            }
        case nil:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first, let group = group(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            if group.title == nil {
                let count = group.tabs.count
                guard count > 0, group === self.model.normalGroup else { return nil }
                return UIMenu(children: [
                    UIAction(title: "New Tab Group with \(count == 1 ? "1 Tab" : "\(count) Tabs")",
                             image: UIImage(systemName: "folder.badge.plus")) { _ in
                        self.askForName(title: "New Tab Group", initial: "", action: "Create") { name in
                            self.model.makeGroup(named: name, movingCurrentTabs: true)
                        }
                    },
                ])
            }
            return UIMenu(children: [
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
                    self.askForName(title: "Rename Tab Group", initial: group.title ?? "", action: "Rename") { name in
                        self.store.rename(group, to: name)
                    }
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.confirmDelete(group)
                },
            ])
        }
    }
}
