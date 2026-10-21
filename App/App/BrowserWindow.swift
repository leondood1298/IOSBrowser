import UIKit

/// The browser's window. Menu bar and keyboard commands travel up the responder chain from
/// whatever has focus, but the address field (in the navigation bar) and the sidebar aren't
/// inside the browser's view, so their chain never meets the browser. Browser commands that
/// reach the window are handed to the browser here, so shortcuts work wherever the focus is.
final class BrowserWindow: UIWindow {
    weak var browser: BrowserViewController?

    /// The browser's own commands (all named "…Command:").
    private func isBrowserCommand(_ action: Selector) -> Bool {
        guard let browser else { return false }
        return NSStringFromSelector(action).hasSuffix("Command:") && browser.responds(to: action)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if isBrowserCommand(action) {
            return browser?.canPerformAction(action, withSender: sender) ?? false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if isBrowserCommand(action), let browser, browser.canPerformAction(action, withSender: sender) {
            return browser
        }
        return super.target(forAction: action, withSender: sender)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let aSelector, isBrowserCommand(aSelector) {
            return browser
        }
        return super.forwardingTarget(for: aSelector)
    }

    override func validate(_ command: UICommand) {
        if isBrowserCommand(command.action) {
            browser?.validate(command)
            return
        }
        super.validate(command)
    }
}
