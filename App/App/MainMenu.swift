import UIKit

/// Builds the iPadOS menu bar and keyboard shortcuts. Each command is sent along the responder
/// chain, so it reaches the browser in the window that's in front.
enum MainMenu {
    static func build(with builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        // UIKit throws on duplicate shortcuts: the system Close menu also claims ⌘W, and the
        // Format menu's Bigger/Smaller claim ⌘+ and ⌘−, which the browser uses for zoom.
        builder.remove(menu: .close)
        builder.remove(menu: .format)

        builder.insertChild(UIMenu(options: .displayInline, children: [
            command("New Tab", #selector(BrowserViewController.newTabCommand(_:)), "t"),
            command("New Private Tab", #selector(BrowserViewController.newPrivateTabCommand(_:)), "n", [.command, .shift]),
            command("Open Location…", #selector(BrowserViewController.openLocationCommand(_:)), "l"),
            command("Close Tab", #selector(BrowserViewController.closeTabCommand(_:)), "w"),
        ]), atStartOfMenu: .file)

        builder.insertChild(UIMenu(options: .displayInline, children: [
            command("Reload Page", #selector(BrowserViewController.reloadCommand(_:)), "r"),
            command("Stop", #selector(BrowserViewController.stopCommand(_:)), "."),
            command("Show All Tabs", #selector(BrowserViewController.showAllTabsCommand(_:)), "\\", [.command, .shift]),
        ]), atStartOfMenu: .view)
        builder.insertChild(UIMenu(options: .displayInline, children: [
            command("Zoom In", #selector(BrowserViewController.zoomInCommand(_:)), "+"),
            hidden(command("Zoom In", #selector(BrowserViewController.zoomInCommand(_:)), "=")),
            command("Zoom Out", #selector(BrowserViewController.zoomOutCommand(_:)), "-"),
            command("Actual Size", #selector(BrowserViewController.actualSizeCommand(_:)), "0"),
        ]), atEndOfMenu: .view)

        let history = UIMenu(title: "History", identifier: UIMenu.Identifier("io.github.leondood1298.browser.history"), children: [
            command("Back", #selector(BrowserViewController.goBackCommand(_:)), "["),
            command("Forward", #selector(BrowserViewController.goForwardCommand(_:)), "]"),
            command("Reopen Closed Tab", #selector(BrowserViewController.reopenClosedTabCommand(_:)), "t", [.command, .shift]),
            command("Show History", #selector(BrowserViewController.showHistoryCommand(_:)), "y"),
        ])
        builder.insertSibling(history, afterMenu: .view)

        let bookmarks = UIMenu(title: "Bookmarks", identifier: UIMenu.Identifier("io.github.leondood1298.browser.bookmarks"), children: [
            command("Add Bookmark", #selector(BrowserViewController.addBookmarkCommand(_:)), "d"),
            command("Show Bookmarks", #selector(BrowserViewController.showBookmarksCommand(_:)), "b", [.command, .alternate]),
        ])
        builder.insertSibling(bookmarks, afterMenu: history.identifier)

        builder.insertChild(UIMenu(options: .displayInline, children: [
            command("Show Next Tab", #selector(BrowserViewController.nextTabCommand(_:)), "\t", [.control]),
            command("Show Previous Tab", #selector(BrowserViewController.previousTabCommand(_:)), "\t", [.control, .shift]),
        ]), atEndOfMenu: .window)
    }

    /// A shortcut that works but doesn't show in the menu (an alternate key for the same command).
    private static func hidden(_ command: UIKeyCommand) -> UIKeyCommand {
        command.attributes = .hidden
        return command
    }

    private static func command(
        _ title: String, _ action: Selector, _ input: String, _ modifiers: UIKeyModifierFlags = .command
    ) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}
