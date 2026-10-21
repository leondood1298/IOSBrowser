import SwiftUI
import UIKit

/// Lists that open in the sidebar.
nonisolated enum LibrarySection {
    case bookmarks
    case history
    case downloads
    case files
}

/// The root of each window: a collapsible sidebar next to the browser.
final class BrowserSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    let model: BrowserWindowModel
    let browser: BrowserViewController
    private let sidebarNavigation: UINavigationController

    init(model: BrowserWindowModel) {
        self.model = model
        browser = BrowserViewController(model: model)
        let sidebar = TabsSidebarViewController(model: model)
        sidebarNavigation = UINavigationController(rootViewController: sidebar)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .secondaryOnly
        preferredSplitBehavior = .tile
        presentsWithGesture = true
        primaryBackgroundStyle = .sidebar
        sidebar.onShowLibrary = { [weak self] section in self?.pushLibrary(section) }
        setViewController(sidebarNavigation, for: .primary)
        setViewController(UINavigationController(rootViewController: browser), for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows bookmarks, history or downloads: in the sidebar when there's room, otherwise as a sheet.
    func showLibrary(_ section: LibrarySection) {
        if section == .files {
            browser.showFiles()
            return
        }
        if traitCollection.horizontalSizeClass == .regular {
            show(.primary)
            sidebarNavigation.popToRootViewController(animated: false)
            pushLibrary(section)
        } else {
            let navigation = UINavigationController(rootViewController: libraryController(section, inSheet: true))
            navigation.modalPresentationStyle = .formSheet
            browser.present(navigation, animated: true)
        }
    }

    private func pushLibrary(_ section: LibrarySection) {
        // The file manager needs the room of a full sheet.
        if section == .files {
            browser.showFiles()
            return
        }
        sidebarNavigation.pushViewController(libraryController(section, inSheet: false), animated: true)
    }

    private func libraryController(_ section: LibrarySection, inSheet: Bool) -> UIViewController {
        let services = model.services
        let open: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            if inSheet {
                self.browser.dismiss(animated: true)
            }
            self.model.open(url)
        }
        let controller: UIViewController
        switch section {
        case .bookmarks:
            controller = UIHostingController(rootView: BookmarksView(
                bookmarks: services.bookmarks, favicons: services.favicons, onOpen: open))
            controller.title = "Bookmarks"
        case .history:
            controller = UIHostingController(rootView: HistoryView(
                history: services.history, favicons: services.favicons, onOpen: open))
            controller.title = "History"
        case .downloads:
            controller = UIHostingController(rootView: DownloadsView(
                manager: services.downloads, actions: browser.downloadActions(dismissingFirst: inSheet)))
            controller.title = "Downloads"
        case .files:
            controller = UIHostingController(rootView: FilesView(files: services.files, actions: browser.fileActions()))
            controller.title = "Files"
        }
        return controller
    }

    /// In a narrow window, show the browser rather than the sidebar.
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        .secondary
    }
}
