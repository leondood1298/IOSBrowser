import UIKit

/// Builds the iPadOS menu bar and keyboard shortcuts. Each command is sent along the responder
/// chain, so it reaches the browser in the window that's in front.
enum MainMenu {
    static func build(with builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        // The system "Close" menu would also claim ⌘W; UIKit throws on duplicate shortcuts.
        builder.remove(menu: .close)

        let fileCommands = UIMenu(options: .displayInline, children: [
            command("New Tab", #selector(BrowserViewController.newTabCommand(_:)), "t"),
            command("New Private Tab", #selector(BrowserViewController.newPrivateTabCommand(_:)), "n", [.command, .shift]),
            command("Open Location…", #selector(BrowserViewController.openLocationCommand(_:)), "l"),
            command("Close Tab", #selector(BrowserViewController.closeTabCommand(_:)), "w"),
        ])
        builder.insertChild(fileCommands, atStartOfMenu: .file)

        let viewCommands = UIMenu(options: .displayInline, children: [
            command("Reload Page", #selector(BrowserViewController.reloadCommand(_:)), "r"),
            command("Stop", #selector(BrowserViewController.stopCommand(_:)), "."),
            command("Show All Tabs", #selector(BrowserViewController.showAllTabsCommand(_:)), "\\", [.command, .shift]),
        ])
        builder.insertChild(viewCommands, atStartOfMenu: .view)

        let history = UIMenu(title: "History", identifier: UIMenu.Identifier("io.github.leondood1298.browser.history"), children: [
            command("Back", #selector(BrowserViewController.goBackCommand(_:)), "["),
            command("Forward", #selector(BrowserViewController.goForwardCommand(_:)), "]"),
        ])
        builder.insertSibling(history, afterMenu: .view)

        let tabs = UIMenu(options: .displayInline, children: [
            command("Show Next Tab", #selector(BrowserViewController.nextTabCommand(_:)), "\t", [.control]),
            command("Show Previous Tab", #selector(BrowserViewController.previousTabCommand(_:)), "\t", [.control, .shift]),
        ])
        builder.insertChild(tabs, atEndOfMenu: .window)
    }

    private static func command(
        _ title: String, _ action: Selector, _ input: String, _ modifiers: UIKeyModifierFlags = .command
    ) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}
