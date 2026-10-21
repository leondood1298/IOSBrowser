import UIKit

/// The root of each window: a collapsible sidebar next to the browser.
final class BrowserSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    let model: BrowserWindowModel
    let browser: BrowserViewController

    init(model: BrowserWindowModel) {
        self.model = model
        browser = BrowserViewController(model: model)
        super.init(style: .doubleColumn)
        delegate = self
        preferredDisplayMode = .secondaryOnly
        preferredSplitBehavior = .tile
        presentsWithGesture = true
        primaryBackgroundStyle = .sidebar
        setViewController(UINavigationController(rootViewController: TabsSidebarViewController(model: model)), for: .primary)
        setViewController(UINavigationController(rootViewController: browser), for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// In a narrow window, show the browser rather than the sidebar.
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        .secondary
    }
}
