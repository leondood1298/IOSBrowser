import UIKit

/// The browser's window. Menu bar and keyboard commands travel up the responder chain from
/// whatever has focus, but the address field (in the navigation bar) and the sidebar aren't
/// inside the browser's view, so their chain never meets the browser, and with nothing focused
/// commands start at the window. The window is in every chain, so it takes the browser's
/// commands as well and passes them on. (When the browser is in the chain it handles them first.)
final class BrowserWindow: UIWindow {
    weak var browser: BrowserViewController?

    override func validate(_ command: UICommand) {
        super.validate(command)
        browser?.validate(command)
    }

    @objc func newTabCommand(_ sender: Any?) { browser?.newTabCommand(sender) }
    @objc func newPrivateTabCommand(_ sender: Any?) { browser?.newPrivateTabCommand(sender) }
    @objc func closeTabCommand(_ sender: Any?) { browser?.closeTabCommand(sender) }
    @objc func reopenClosedTabCommand(_ sender: Any?) { browser?.reopenClosedTabCommand(sender) }
    @objc func openLocationCommand(_ sender: Any?) { browser?.openLocationCommand(sender) }
    @objc func reloadCommand(_ sender: Any?) { browser?.reloadCommand(sender) }
    @objc func stopCommand(_ sender: Any?) { browser?.stopCommand(sender) }
    @objc func goBackCommand(_ sender: Any?) { browser?.goBackCommand(sender) }
    @objc func goForwardCommand(_ sender: Any?) { browser?.goForwardCommand(sender) }
    @objc func showAllTabsCommand(_ sender: Any?) { browser?.showAllTabsCommand(sender) }
    @objc func nextTabCommand(_ sender: Any?) { browser?.nextTabCommand(sender) }
    @objc func previousTabCommand(_ sender: Any?) { browser?.previousTabCommand(sender) }
    @objc func addBookmarkCommand(_ sender: Any?) { browser?.addBookmarkCommand(sender) }
    @objc func showBookmarksCommand(_ sender: Any?) { browser?.showBookmarksCommand(sender) }
    @objc func showHistoryCommand(_ sender: Any?) { browser?.showHistoryCommand(sender) }
    @objc func zoomInCommand(_ sender: Any?) { browser?.zoomInCommand(sender) }
    @objc func zoomOutCommand(_ sender: Any?) { browser?.zoomOutCommand(sender) }
    @objc func actualSizeCommand(_ sender: Any?) { browser?.actualSizeCommand(sender) }
    @objc func showSettingsCommand(_ sender: Any?) { browser?.showSettingsCommand(sender) }
    @objc func eraseCommand(_ sender: Any?) { browser?.eraseCommand(sender) }
    @objc func selectTabCommand(_ sender: UICommand) { browser?.selectTabCommand(sender) }
}
