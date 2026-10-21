import BrowserCore
import Combine
import SwiftUI
import UIKit
import WebKit

/// The browser itself: toolbar with the address field, the tab strip, and the selected tab's
/// web view (or the New Tab page).
final class BrowserViewController: UIViewController {
    let model: BrowserWindowModel

    private let addressField = AddressField()
    private let tabStrip = TabStripView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let contentView = UIView()
    private var startPageHost: UIHostingController<NewTabPageView>?
    private weak var displayedWebView: WKWebView?
    private var modelObservers: Set<AnyCancellable> = []
    private var tabObservers: Set<AnyCancellable> = []

    private lazy var backButton = barButton("chevron.backward", label: "Back", id: "backButton") { [weak self] in
        self?.model.selectedTab?.goBack()
    }
    private lazy var forwardButton = barButton("chevron.forward", label: "Forward", id: "forwardButton") { [weak self] in
        self?.model.selectedTab?.goForward()
    }
    private lazy var tabsButton = barButton("square.on.square", label: "Show All Tabs", id: "tabOverviewButton") { [weak self] in
        self?.showTabOverview()
    }
    private lazy var newTabButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.openNewTab(isPrivate: nil) },
            menu: UIMenu(children: [
                UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                    self?.openNewTab(isPrivate: false)
                },
                UIAction(title: "New Private Tab", image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                    self?.openNewTab(isPrivate: true)
                },
            ]))
        item.accessibilityLabel = "New Tab"
        item.accessibilityIdentifier = "newTabButton"
        return item
    }()
    private lazy var moreButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(title: "Diagnostics", image: UIImage(systemName: "stethoscope")) { [weak self] _ in
                    self?.showDiagnostics()
                },
            ]))
        item.accessibilityLabel = "More"
        item.accessibilityIdentifier = "moreButton"
        return item
    }()

    init(model: BrowserWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        model.tabDelegate = self
        configureNavigationItem()
        configureLayout()
        configureCallbacks()

        model.$selectedTab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in self?.show(tab) }
            .store(in: &modelObservers)
        model.normalGroup.$tabs.combineLatest(model.privateGroup.$tabs, model.$isPrivate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refreshTabStrip() }
            .store(in: &modelObservers)
        model.$isPrivate
            .receive(on: RunLoop.main)
            .sink { [weak self] isPrivate in self?.applyPrivateAppearance(isPrivate) }
            .store(in: &modelObservers)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if model.selectedTab?.showsStartPage == true {
            addressField.beginEditingAddress()
        }
    }

    // MARK: - Setup

    private func configureNavigationItem() {
        navigationItem.style = .browser
        navigationItem.titleView = addressField
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItems = [backButton, forwardButton]
        navigationItem.rightBarButtonItems = [moreButton, tabsButton, newTabButton]
    }

    private func configureLayout() {
        for subview in [tabStrip, contentView, progressView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        progressView.isHidden = true
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 38),
            progressView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureCallbacks() {
        addressField.onSubmit = { [weak self] input in
            guard let self else { return }
            self.model.open(input: input)
        }
        addressField.onReloadOrStop = { [weak self] in
            guard let tab = self?.model.selectedTab else { return }
            if tab.isLoading { tab.stopLoading() } else { tab.reload() }
        }
        tabStrip.onSelect = { [weak self] tab in self?.model.select(tab) }
        tabStrip.onClose = { [weak self] tab in self?.model.close(tab) }
        tabStrip.onMove = { [weak self] from, to in self?.model.moveTab(from: from, to: to) }
    }

    private func barButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { _ in action() })
        item.accessibilityLabel = label
        item.accessibilityIdentifier = id
        return item
    }

    // MARK: - Showing the selected tab

    private func show(_ tab: TabModel?) {
        tabObservers.removeAll()
        refreshTabStrip()
        guard let tab else {
            displayedWebView?.removeFromSuperview()
            showStartPage(isPrivate: model.isPrivate)
            return
        }

        tab.$showsStartPage
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] showsStartPage in
                guard let self, let tab else { return }
                if showsStartPage {
                    self.displayedWebView?.removeFromSuperview()
                    self.showStartPage(isPrivate: tab.isPrivate)
                } else {
                    self.hideStartPage()
                    self.display(tab.makeWebViewIfNeeded(), for: tab)
                }
            }
            .store(in: &tabObservers)

        tab.$url.combineLatest(tab.$hasOnlySecureContent, tab.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] url, secure, loading in
                self?.addressField.update(url: url, isSecure: secure, isLoading: loading)
            }
            .store(in: &tabObservers)
        tab.$canGoBack.combineLatest(tab.$canGoForward)
            .receive(on: RunLoop.main)
            .sink { [weak self] back, forward in
                self?.backButton.isEnabled = back
                self?.forwardButton.isEnabled = forward
            }
            .store(in: &tabObservers)
        tab.$estimatedProgress.combineLatest(tab.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] progress, loading in self?.updateProgress(progress, isLoading: loading) }
            .store(in: &tabObservers)
    }

    private func display(_ webView: WKWebView, for tab: TabModel) {
        if displayedWebView !== webView {
            displayedWebView?.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: contentView.topAnchor),
                webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
            displayedWebView = webView
        }
        WebViewBudget.shared.didShow(tab, visibleTabIDs: [tab.id])
    }

    private func showStartPage(isPrivate: Bool) {
        let page = NewTabPageView(isPrivate: isPrivate)
        if let host = startPageHost {
            host.rootView = page
            host.view.isHidden = false
            contentView.bringSubviewToFront(host.view)
            return
        }
        let host = UIHostingController(rootView: page)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        host.didMove(toParent: self)
        startPageHost = host
    }

    private func hideStartPage() {
        startPageHost?.view.isHidden = true
    }

    private func refreshTabStrip() {
        tabStrip.update(tabs: model.activeGroup.tabs, selectedID: model.selectedTab?.id)
    }

    private func updateProgress(_ progress: Double, isLoading: Bool) {
        progressView.isHidden = !isLoading
        progressView.setProgress(Float(progress), animated: isLoading && progress > 0.05)
    }

    private func applyPrivateAppearance(_ isPrivate: Bool) {
        navigationController?.overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
        overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
        addressField.placeholder = isPrivate ? "Search or enter address (Private)" : "Search or enter address"
    }

    // MARK: - Actions

    func openNewTab(isPrivate: Bool?) {
        model.newTab(isPrivate: isPrivate)
        addressField.beginEditingAddress()
    }

    func focusAddressField() {
        addressField.beginEditingAddress()
    }

    func showTabOverview() {
        model.selectedTab?.captureSnapshot()
        let overview = TabOverviewViewController(model: model)
        present(overview, animated: true)
    }

    private func showDiagnostics() {
        let host = UIHostingController(rootView: NavigationStack { DiagnosticsView() })
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    /// Opens URLs handed to the app (iosbrowser:// links) in a new tab.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "iosbrowser" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let wantsPrivate = items.first { $0.name == "private" }?.value == "1"
        let input: String?
        switch url.host?.lowercased() {
        case "open-url": input = items.first { $0.name == "url" }?.value
        case "open-text": input = items.first { $0.name == "text" }?.value
        default: input = nil
        }
        guard let input, let target = BrowserWindowModel.url(for: input, engine: model.services.preferences.searchEngine)
        else { return }
        model.newTab(url: target, isPrivate: wantsPrivate)
    }
}

// MARK: - TabModelDelegate

extension BrowserViewController: TabModelDelegate {
    func tab(_ tab: TabModel, createWebViewWith configuration: WKWebViewConfiguration,
             for navigationAction: WKNavigationAction) -> WKWebView? {
        model.openPopup(configuration: configuration, from: tab)
    }

    func tabDidRequestClose(_ tab: TabModel) {
        model.close(tab)
    }

    func presenter(for tab: TabModel) -> UIViewController? {
        guard tab === model.selectedTab, viewIfLoaded?.window != nil else { return nil }
        return self
    }
}

// MARK: - Keyboard and menu bar commands

extension BrowserViewController {
    @objc func newTabCommand(_ sender: Any?) { openNewTab(isPrivate: false) }
    @objc func newPrivateTabCommand(_ sender: Any?) { openNewTab(isPrivate: true) }
    @objc func closeTabCommand(_ sender: Any?) {
        if let tab = model.selectedTab { model.close(tab) }
    }
    @objc func openLocationCommand(_ sender: Any?) { focusAddressField() }
    @objc func reloadCommand(_ sender: Any?) { model.selectedTab?.reload() }
    @objc func stopCommand(_ sender: Any?) { model.selectedTab?.stopLoading() }
    @objc func goBackCommand(_ sender: Any?) { model.selectedTab?.goBack() }
    @objc func goForwardCommand(_ sender: Any?) { model.selectedTab?.goForward() }
    @objc func showAllTabsCommand(_ sender: Any?) { showTabOverview() }
    @objc func nextTabCommand(_ sender: Any?) { model.selectNextTab(offset: 1) }
    @objc func previousTabCommand(_ sender: Any?) { model.selectNextTab(offset: -1) }

    override func validate(_ command: UICommand) {
        super.validate(command)
        switch command.action {
        case #selector(goBackCommand(_:)):
            command.attributes = model.selectedTab?.canGoBack == true ? [] : .disabled
        case #selector(goForwardCommand(_:)):
            command.attributes = model.selectedTab?.canGoForward == true ? [] : .disabled
        default:
            break
        }
    }
}
