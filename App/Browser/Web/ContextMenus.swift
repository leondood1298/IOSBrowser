import UIKit
import WebKit

/// What a long-press menu can ask the window to do.
protocol ContextMenuHandler: AnyObject {
    func openInNewTab(_ url: URL, from tab: TabModel, background: Bool, isPrivate: Bool)
    func openInNewWindow(_ url: URL, isPrivate: Bool)
    func share(_ items: [Any], from tab: TabModel)
    func addShortcut(title: String, url: URL)
    func addBookmark(title: String, url: URL)
    func downloadLink(_ url: URL, from tab: TabModel)
    func imageAction(_ action: ContextMenus.ImageAction, url: URL, from tab: TabModel)
    /// The menu for a long-pressed image that isn't a link (WebKit offers none for those).
    func showImageMenu(_ url: URL, at point: CGPoint, in sourceView: UIView, from tab: TabModel)
}

/// Builds the long-press menus for links and images (WebKit supplies the link preview).
enum ContextMenus {
    enum ImageAction {
        case saveToPhotos
        case copy
        case share
        case download
    }

    static func configuration(
        link: URL?, image: URL?, linkTitle: String?, tab: TabModel, handler: ContextMenuHandler
    ) -> UIContextMenuConfiguration? {
        guard link != nil || image != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak handler, weak tab] _ in
            guard let handler, let tab else { return nil }
            var sections: [UIMenuElement] = []
            if let link {
                sections.append(linkMenu(link, title: linkTitle, tab: tab, handler: handler))
            }
            if let image {
                sections.append(imageMenu(image, tab: tab, handler: handler))
            }
            return UIMenu(children: sections)
        }
    }

    private static func linkMenu(_ url: URL, title: String?, tab: TabModel, handler: ContextMenuHandler) -> UIMenu {
        let open = UIMenu(options: .displayInline, children: [
            UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                handler.openInNewTab(url, from: tab, background: false, isPrivate: tab.isPrivate)
            },
            UIAction(title: "Open in Background", image: UIImage(systemName: "square.on.square.dashed")) { _ in
                handler.openInNewTab(url, from: tab, background: true, isPrivate: tab.isPrivate)
            },
            UIAction(title: "Open in New Private Tab", image: UIImage(systemName: "hand.raised")) { _ in
                handler.openInNewTab(url, from: tab, background: false, isPrivate: true)
            },
            UIAction(title: "Open in New Window", image: UIImage(systemName: "macwindow.badge.plus")) { _ in
                handler.openInNewWindow(url, isPrivate: tab.isPrivate)
            },
        ])
        let save = UIMenu(options: .displayInline, children: [
            UIAction(title: "Download Linked File", image: UIImage(systemName: "arrow.down.circle")) { _ in
                handler.downloadLink(url, from: tab)
            },
            UIAction(title: "Add to Shortcuts", image: UIImage(systemName: "square.grid.2x2")) { _ in
                handler.addShortcut(title: title ?? "", url: url)
            },
            UIAction(title: "Add Bookmark", image: UIImage(systemName: "book")) { _ in
                handler.addBookmark(title: title ?? "", url: url)
            },
        ])
        let copy = UIMenu(options: .displayInline, children: [
            UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            },
            UIAction(title: "Share Link…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                handler.share([url], from: tab)
            },
        ])
        return UIMenu(options: .displayInline, children: [open, save, copy])
    }

    private static func imageMenu(_ url: URL, tab: TabModel, handler: ContextMenuHandler) -> UIMenu {
        UIMenu(title: "Image", options: .displayInline, children: [
            UIAction(title: "Open Image in New Tab", image: UIImage(systemName: "photo.on.rectangle")) { _ in
                handler.openInNewTab(url, from: tab, background: false, isPrivate: tab.isPrivate)
            },
            UIAction(title: "Save to Photos", image: UIImage(systemName: "photo.badge.arrow.down")) { _ in
                handler.imageAction(.saveToPhotos, url: url, from: tab)
            },
            UIAction(title: "Save to Downloads", image: UIImage(systemName: "arrow.down.doc")) { _ in
                handler.imageAction(.download, url: url, from: tab)
            },
            UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.clipboard")) { _ in
                handler.imageAction(.copy, url: url, from: tab)
            },
            UIAction(title: "Share Image…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                handler.imageAction(.share, url: url, from: tab)
            },
        ])
    }
}
