import BrowserCore
import Combine
import SwiftUI
import UIKit
import WebKit

/// The browser itself: toolbar with the address field, the tab strip, and the selected tab's
/// web view (or the New Tab page).
final class BrowserViewController: UIViewController {
    let model: BrowserWindowModel

    private var services: AppServices { model.services }
    private let addressField = AddressField()
    private let tabStrip = TabStripView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let contentView = UIView()
    private var startPageHost: UIHostingController<StartPageView>?
    private var suggestionsHost: UIHostingController<SuggestionsView>?
    private lazy var suggestions = SuggestionsModel(services: services, window: model)
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
    private lazy var shareButton: UIBarButtonItem = barButton("square.and.arrow.up", label: "Share", id: "shareButton") { [weak self] in
        guard let self, let tab = self.model.selectedTab, !tab.showsStartPage else { return }
        PageActions.share(tab, from: self, source: self.shareButton)
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
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.recentlyClosedMenu() ?? [])
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
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.pageMenuElements() ?? [])
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
        tabStrip.favicons = services.favicons
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
        navigationItem.rightBarButtonItems = [moreButton, tabsButton, newTabButton, shareButton]
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
            self?.model.open(input: input)
        }
        addressField.onPasteAndGo = { [weak self] input in
            self?.model.open(input: input)
        }
        addressField.onReloadOrStop = { [weak self] in
            guard let tab = self?.model.selectedTab else { return }
            if tab.isLoading { tab.stopLoading() } else { tab.reload() }
        }
        addressField.onPageSettings = { [weak self] source in self?.showPageSettings(from: source) }
        addressField.onTextChange = { [weak self] text in self?.showSuggestions(for: text) }
        addressField.onEditingEnded = { [weak self] in self?.hideSuggestions() }
        tabStrip.onSelect = { [weak self] tab in self?.model.select(tab) }
        tabStrip.onClose = { [weak self] tab in self?.model.close(tab) }
        tabStrip.onMove = { [weak self] from, to in self?.model.moveTab(from: from, to: to) }
        tabStrip.onToggleMute = { tab in tab.setMuted(!tab.isMuted) }
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

        addressField.showTab(url: tab.url)
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
        tab.$showsStartPage
            .receive(on: RunLoop.main)
            .sink { [weak self] showsStartPage in self?.shareButton.isEnabled = !showsStartPage }
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
        let page = StartPageView(
            isPrivate: isPrivate,
            actions: StartPageActions(open: { [weak self] url in self?.model.open(url) }),
            bookmarks: services.bookmarks, history: services.history, favicons: services.favicons)
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

    // MARK: - Suggestions

    private func showSuggestions(for text: String) {
        suggestions.update(query: text)
        let hasContent = !suggestions.results.isEmpty || suggestions.canPaste
        if suggestionsHost == nil && hasContent {
            let host = UIHostingController(rootView: SuggestionsView(
                model: suggestions, favicons: services.favicons,
                onSelect: { [weak self] suggestion in self?.choose(suggestion) },
                onPasteAndGo: { [weak self] in self?.pasteAndGo() }))
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            suggestionsHost = host
        }
        suggestionsHost?.view.isHidden = !hasContent
    }

    private func hideSuggestions() {
        guard let host = suggestionsHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        suggestionsHost = nil
    }

    private func choose(_ suggestion: Suggestion) {
        addressField.resignFirstResponder()
        if case .openTab(let id) = suggestion.kind, let tab = model.allTabs.first(where: { $0.id == id }) {
            model.select(tab)
        } else {
            model.open(suggestion.url)
        }
    }

    private func pasteAndGo() {
        let pasted = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
        addressField.resignFirstResponder()
        if !pasted.isEmpty {
            model.open(input: pasted)
        }
    }

    // MARK: - Menus

    private func recentlyClosedMenu() -> [UIMenuElement] {
        let closed = model.recentlyClosed.prefix(10)
        guard !closed.isEmpty else { return [] }
        let items = closed.map { entry in
            UIAction(title: entry.title, image: UIImage(systemName: entry.isPrivate ? "hand.raised" : "clock.arrow.circlepath")) {
                [weak self] _ in self?.model.reopen(entry)
            }
        }
        return [UIMenu(title: "Recently Closed", image: UIImage(systemName: "clock.arrow.circlepath"), children: items)]
    }

    private func pageMenuElements() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        if let tab = model.selectedTab, let url = tab.url, !tab.showsStartPage {
            let bookmarked = services.bookmarks.isBookmarked(url)
            let pinned = services.bookmarks.hasShortcut(for: url)
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: bookmarked ? "Remove Bookmark" : "Add Bookmark",
                         image: UIImage(systemName: bookmarked ? "book.fill" : "book")) { [weak self] _ in
                    self?.toggleBookmark()
                },
                UIAction(title: pinned ? "Remove from Shortcuts" : "Add to Shortcuts",
                         image: UIImage(systemName: pinned ? "square.grid.2x2.fill" : "square.grid.2x2")) { [weak self] _ in
                    self?.toggleShortcut()
                },
            ]))
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Find on Page", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                    self?.findOnPage()
                },
                UIAction(title: "Copy Address", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                },
                UIAction(title: "Print…", image: UIImage(systemName: "printer")) { _ in
                    PageActions.print(tab)
                },
                UIAction(title: "Save as PDF", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in
                    self?.savePage(asPDF: true)
                },
                UIAction(title: "Save as Web Archive", image: UIImage(systemName: "archivebox")) { [weak self] _ in
                    self?.savePage(asPDF: false)
                },
            ]))
            let browsers = PageActions.otherBrowsers(for: url).map { browser in
                UIAction(title: browser.name) { _ in
                    UIApplication.shared.open(browser.url)
                }
            }
            if !browsers.isEmpty {
                sections.append(UIMenu(title: "Open In", image: UIImage(systemName: "safari"), children: browsers))
            }
        }
        sections.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Bookmarks", image: UIImage(systemName: "book")) { [weak self] _ in
                self?.showLibrary(.bookmarks)
            },
            UIAction(title: "History", image: UIImage(systemName: "clock")) { [weak self] _ in
                self?.showLibrary(.history)
            },
        ]))
        sections.append(UIAction(title: "Diagnostics", image: UIImage(systemName: "stethoscope")) { [weak self] _ in
            self?.showDiagnostics()
        })
        return sections
    }

    // MARK: - Actions

    func openNewTab(isPrivate: Bool?) {
        model.newTab(isPrivate: isPrivate)
        DispatchQueue.main.async { [weak self] in
            self?.addressField.beginEditingAddress()
        }
    }

    func focusAddressField() {
        addressField.beginEditingAddress()
    }

    func showTabOverview() {
        guard presentedViewController == nil else { return }
        let presentOverview = { [weak self] in
            guard let self, self.presentedViewController == nil else { return }
            self.present(TabOverviewViewController(model: self.model), animated: true)
        }
        if let tab = model.selectedTab {
            tab.captureSnapshot(completion: presentOverview)
        } else {
            presentOverview()
        }
    }

    func showLibrary(_ section: LibrarySection) {
        if let split = splitViewController as? BrowserSplitViewController {
            split.showLibrary(section)
        }
    }

    private func showPageSettings(from source: UIView) {
        guard let tab = model.selectedTab, presentedViewController == nil else { return }
        let settings = PageSettingsModel(tab: tab, services: services)
        settings.onFind = { [weak self] in
            self?.dismiss(animated: true) { self?.findOnPage() }
        }
        let host = UIHostingController(rootView: PageSettingsView(model: settings))
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .popover
        host.popoverPresentationController?.sourceView = source
        host.popoverPresentationController?.sourceRect = source.bounds
        host.popoverPresentationController?.permittedArrowDirections = [.up]
        present(host, animated: true)
    }

    private func findOnPage() {
        displayedWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    private func toggleBookmark() {
        guard let tab = model.selectedTab, let url = tab.url else { return }
        if services.bookmarks.isBookmarked(url) {
            services.bookmarks.removeBookmark(for: url)
            Toast.show("Bookmark removed", systemImage: "book", in: view)
        } else {
            services.bookmarks.addBookmark(title: tab.pageTitle, url: url)
            Toast.show("Bookmark added", systemImage: "book.fill", in: view)
        }
    }

    private func toggleShortcut() {
        guard let tab = model.selectedTab, let url = tab.url else { return }
        if services.bookmarks.hasShortcut(for: url) {
            services.bookmarks.removeShortcut(for: url)
            Toast.show("Removed from Shortcuts", systemImage: "square.grid.2x2", in: view)
        } else {
            services.bookmarks.addShortcut(title: tab.pageTitle, url: url)
            Toast.show("Added to Shortcuts", systemImage: "square.grid.2x2.fill", in: view)
        }
    }

    private func savePage(asPDF: Bool) {
        guard let tab = model.selectedTab else { return }
        Task {
            do {
                let file: URL
                if asPDF {
                    file = try await PageActions.savePDF(tab)
                } else {
                    file = try await PageActions.saveWebArchive(tab)
                }
                Toast.show("Saved \(file.lastPathComponent) to Downloads", systemImage: "arrow.down.doc", in: view)
            } catch {
                Toast.show("Couldn't save this page", systemImage: "exclamationmark.triangle", in: view)
            }
        }
    }

    private func adjustZoom(_ direction: Int) {
        guard let tab = model.selectedTab, !tab.showsStartPage else { return }
        let current = tab.currentZoom
        let next: Double
        if direction > 0 {
            next = ZoomLevels.next(after: current)
        } else if direction < 0 {
            next = ZoomLevels.previous(before: current)
        } else {
            next = services.preferences.defaultZoom
        }
        tab.setZoom(next, remember: true)
        Toast.show(ZoomLevels.percentText(next), systemImage: "plus.magnifyingglass", in: view)
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
        guard let input, let target = BrowserWindowModel.url(for: input, engine: services.preferences.searchEngine)
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

    // MARK: ContextMenuHandler

    func openInNewTab(_ url: URL, from tab: TabModel, background: Bool, isPrivate: Bool) {
        let opener = isPrivate == tab.isPrivate ? tab : nil
        model.newTab(url: url, isPrivate: isPrivate, after: opener, select: !background)
        if background {
            Toast.show("Opened in a background tab", systemImage: "square.on.square", in: view)
        }
    }

    func openInNewWindow(_ url: URL, isPrivate: Bool) {
        let activity = NSUserActivity(activityType: SceneDelegate.openURLActivityType)
        activity.userInfo = ["url": url.absoluteString, "private": isPrivate]
        let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity)
        UIApplication.shared.activateSceneSession(for: request) { error in
            Log.event("Opening a new window failed: \(error.localizedDescription)")
        }
    }

    func share(_ items: [Any], from tab: TabModel) {
        PageActions.share(items: items, from: self, sourceView: displayedWebView ?? view)
    }

    func addShortcut(title: String, url: URL) {
        services.bookmarks.addShortcut(title: title, url: url)
        Toast.show("Added to Shortcuts", systemImage: "square.grid.2x2.fill", in: view)
    }

    func addBookmark(title: String, url: URL) {
        services.bookmarks.addBookmark(title: title, url: url)
        Toast.show("Bookmark added", systemImage: "book.fill", in: view)
    }

    func downloadLink(_ url: URL, from tab: TabModel) {
        Toast.show("The download manager arrives in the next version", systemImage: "arrow.down.circle", in: view)
    }

    func imageAction(_ action: ContextMenus.ImageAction, url: URL, from tab: TabModel) {
        Task {
            do {
                let image = try await ImageActions.fetch(url, for: tab)
                switch action {
                case .saveToPhotos:
                    try await ImageActions.saveToPhotos(image.data)
                    Toast.show("Saved to Photos", systemImage: "photo", in: view)
                case .copy:
                    ImageActions.copy(image.data, type: image.type)
                    Toast.show("Image copied", systemImage: "doc.on.clipboard", in: view)
                case .download:
                    let file = try ImageActions.saveToDownloads(image.data, filename: image.filename, type: image.type)
                    Toast.show("Saved \(file.lastPathComponent) to Downloads", systemImage: "arrow.down.doc", in: view)
                case .share:
                    let file = try ImageActions.temporaryFile(image.data, filename: image.filename, type: image.type)
                    share([file], from: tab)
                }
            } catch {
                Toast.show(error.localizedDescription, systemImage: "exclamationmark.triangle", in: view)
            }
        }
    }
}

// MARK: - Keyboard and menu bar commands

extension BrowserViewController {
    @objc func newTabCommand(_ sender: Any?) { openNewTab(isPrivate: false) }
    @objc func newPrivateTabCommand(_ sender: Any?) { openNewTab(isPrivate: true) }
    @objc func closeTabCommand(_ sender: Any?) {
        if let tab = model.selectedTab { model.close(tab) }
    }
    @objc func reopenClosedTabCommand(_ sender: Any?) { model.reopenLastClosedTab() }
    @objc func openLocationCommand(_ sender: Any?) { focusAddressField() }
    @objc func reloadCommand(_ sender: Any?) { model.selectedTab?.reload() }
    @objc func stopCommand(_ sender: Any?) { model.selectedTab?.stopLoading() }
    @objc func goBackCommand(_ sender: Any?) { model.selectedTab?.goBack() }
    @objc func goForwardCommand(_ sender: Any?) { model.selectedTab?.goForward() }
    @objc func showAllTabsCommand(_ sender: Any?) { showTabOverview() }
    @objc func nextTabCommand(_ sender: Any?) { model.selectNextTab(offset: 1) }
    @objc func previousTabCommand(_ sender: Any?) { model.selectNextTab(offset: -1) }
    @objc func addBookmarkCommand(_ sender: Any?) { toggleBookmark() }
    @objc func showBookmarksCommand(_ sender: Any?) { showLibrary(.bookmarks) }
    @objc func showHistoryCommand(_ sender: Any?) { showLibrary(.history) }
    @objc func zoomInCommand(_ sender: Any?) { adjustZoom(1) }
    @objc func zoomOutCommand(_ sender: Any?) { adjustZoom(-1) }
    @objc func actualSizeCommand(_ sender: Any?) { adjustZoom(0) }

    override func validate(_ command: UICommand) {
        super.validate(command)
        switch command.action {
        case #selector(goBackCommand(_:)):
            command.attributes = model.selectedTab?.canGoBack == true ? [] : .disabled
        case #selector(goForwardCommand(_:)):
            command.attributes = model.selectedTab?.canGoForward == true ? [] : .disabled
        case #selector(reopenClosedTabCommand(_:)):
            command.attributes = model.recentlyClosed.isEmpty ? .disabled : []
        default:
            break
        }
    }
}
