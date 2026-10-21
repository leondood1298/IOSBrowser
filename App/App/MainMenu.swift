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

        builder.insertChild(UIMenu(options: .displayInline, children: fileCommands), atStartOfMenu: .file)
        builder.insertChild(UIMenu(options: .displayInline, children: eraseCommands), atEndOfMenu: .file)
        builder.insertChild(UIMenu(options: .displayInline, children: viewCommands), atStartOfMenu: .view)
        builder.insertChild(UIMenu(options: .displayInline, children: zoomCommands), atEndOfMenu: .view)

        let history = UIMenu(
            title: "History", identifier: UIMenu.Identifier("io.github.leondood1298.browser.history"),
            children: historyCommands)
        builder.insertSibling(history, afterMenu: .view)
        let bookmarks = UIMenu(
            title: "Bookmarks", identifier: UIMenu.Identifier("io.github.leondood1298.browser.bookmarks"),
            children: bookmarkCommands)
        builder.insertSibling(bookmarks, afterMenu: history.identifier)

        builder.insertChild(UIMenu(options: .displayInline, children: tabCommands), atEndOfMenu: .window)

        // Settings… (⌘,) replaces whatever the system puts in the app menu's settings slot.
        let settings = settingsCommand
        if builder.menu(for: .preferences) != nil {
            builder.replaceChildren(ofMenu: .preferences) { _ in [settings] }
        } else {
            builder.insertSibling(UIMenu(options: .displayInline, children: [settings]), afterMenu: .about)
        }
    }

    /// Every command the browser adds. BrowserWindow must forward each one (a unit test checks).
    static var allCommands: [UIKeyCommand] {
        fileCommands + eraseCommands + viewCommands + zoomCommands + historyCommands + bookmarkCommands
            + tabCommands + [settingsCommand]
    }

    private static var fileCommands: [UIKeyCommand] {
        [
            command("New Tab", #selector(BrowserViewController.newTabCommand(_:)), "t"),
            command("New Private Tab", #selector(BrowserViewController.newPrivateTabCommand(_:)), "n", [.command, .shift]),
            command("Open Location…", #selector(BrowserViewController.openLocationCommand(_:)), "l"),
            command("Close Tab", #selector(BrowserViewController.closeTabCommand(_:)), "w"),
        ]
    }

    private static var eraseCommands: [UIKeyCommand] {
        [
            command("Erase / Clear Browsing Data…", #selector(BrowserViewController.eraseCommand(_:)),
                    UIKeyCommand.inputDelete, [.command, .shift]),
        ]
    }

    private static var viewCommands: [UIKeyCommand] {
        [
            command("Reload Page", #selector(BrowserViewController.reloadCommand(_:)), "r"),
            command("Stop", #selector(BrowserViewController.stopCommand(_:)), "."),
            command("Show All Tabs", #selector(BrowserViewController.showAllTabsCommand(_:)), "\\", [.command, .shift]),
        ]
    }

    private static var zoomCommands: [UIKeyCommand] {
        [
            command("Zoom In", #selector(BrowserViewController.zoomInCommand(_:)), "+"),
            command("Zoom In", #selector(BrowserViewController.zoomInCommand(_:)), "=", propertyList: "equals", hidden: true),
            command("Zoom Out", #selector(BrowserViewController.zoomOutCommand(_:)), "-"),
            command("Actual Size", #selector(BrowserViewController.actualSizeCommand(_:)), "0"),
        ]
    }

    private static var historyCommands: [UIKeyCommand] {
        [
            command("Back", #selector(BrowserViewController.goBackCommand(_:)), "["),
            command("Forward", #selector(BrowserViewController.goForwardCommand(_:)), "]"),
            command("Reopen Closed Tab", #selector(BrowserViewController.reopenClosedTabCommand(_:)), "t", [.command, .shift]),
            command("Show History", #selector(BrowserViewController.showHistoryCommand(_:)), "y"),
        ]
    }

    private static var bookmarkCommands: [UIKeyCommand] {
        [
            command("Add Bookmark", #selector(BrowserViewController.addBookmarkCommand(_:)), "d"),
            command("Show Bookmarks", #selector(BrowserViewController.showBookmarksCommand(_:)), "b", [.command, .alternate]),
        ]
    }

    private static var tabCommands: [UIKeyCommand] {
        var commands = [
            command("Show Next Tab", #selector(BrowserViewController.nextTabCommand(_:)), "\t", [.control]),
            command("Show Previous Tab", #selector(BrowserViewController.previousTabCommand(_:)), "\t", [.control, .shift]),
        ]
        for number in 1...9 {
            commands.append(command(
                number == 9 ? "Show Last Tab" : "Show Tab \(number)",
                #selector(BrowserViewController.selectTabCommand(_:)), "\(number)",
                propertyList: number, hidden: true))
        }
        return commands
    }

    private static var settingsCommand: UIKeyCommand {
        command("Settings…", #selector(BrowserViewController.showSettingsCommand(_:)), ",")
    }

    /// Commands must have unique (action, propertyList) pairs, or UIKit throws while building the
    /// menu. An alternate key for the same action passes its own `propertyList` and is hidden.
    private static func command(
        _ title: String, _ action: Selector, _ input: String, _ modifiers: UIKeyModifierFlags = .command,
        propertyList: Any? = nil, hidden: Bool = false
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            title: title, image: nil, action: action, input: input, modifierFlags: modifiers,
            propertyList: propertyList, alternates: [], discoverabilityTitle: nil,
            attributes: hidden ? .hidden : [], state: .off)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}
