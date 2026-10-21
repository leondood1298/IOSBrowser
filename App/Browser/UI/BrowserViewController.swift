import BrowserCore
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The browser itself: toolbar with the address field, the tab strip, and the selected tab's
/// web view (or the New Tab page).
final class BrowserViewController: UIViewController {
    let model: BrowserWindowModel

    var services: AppServices { model.services }
    let addressField = AddressField()
    private let tabStrip = TabStripView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let contentView = UIView()
    private var startPageHost: UIHostingController<StartPageView>?
    private var suggestionsHost: UIHostingController<SuggestionsView>?
    private lazy var suggestions = SuggestionsModel(services: services, window: model)
    private weak var displayedWebView: WKWebView?
    private var modelObservers: Set<AnyCancellable> = []
    private var tabObservers: Set<AnyCancellable> = []
    private var tabStripHeight: NSLayoutConstraint?

    private lazy var backButton = barButton("chevron.backward", label: "Back", id: "backButton") { [weak self] in
        self?.model.selectedTab?.goBack()
    }
    private lazy var forwardButton = barButton("chevron.forward", label: "Forward", id: "forwardButton") { [weak self] in
        self?.model.selectedTab?.goForward()
    }
    private lazy var tabsButton = barButton("square.on.square", label: "Show All Tabs", id: "tabOverviewButton") { [weak self] in
        self?.showTabOverview()
    }
    private lazy var eraseButton: UIBarButtonItem = barButton("trash", label: "Erase", id: "eraseButton") { [weak self] in
        self?.erasePrivateBrowsing()
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
    private lazy var downloadsRing: DownloadsRingView = {
        let ring = DownloadsRingView()
        ring.addAction(UIAction { [weak self] _ in self?.showDownloadsPopover() }, for: .touchUpInside)
        return ring
    }()
    private lazy var downloadsButton: UIBarButtonItem = {
        let item = UIBarButtonItem(customView: downloadsRing)
        item.accessibilityLabel = "Downloads"
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
        configureLayout()
        configureCallbacks()
        applyWidthLayout()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (controller: BrowserViewController, _: UITraitCollection) in
            controller.applyWidthLayout()
        }

        model.$selectedTab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in self?.show(tab) }
            .store(in: &modelObservers)
        model.$normalTabs.combineLatest(model.$privateTabs, model.$isPrivate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refreshTabStrip() }
            .store(in: &modelObservers)
        model.$isPrivate
            .receive(on: RunLoop.main)
            .sink { [weak self] isPrivate in self?.applyPrivateAppearance(isPrivate) }
            .store(in: &modelObservers)
        observeDownloads()
        observeAudio()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if model.selectedTab?.showsStartPage == true {
            addressField.beginEditingAddress()
        } else {
            takeFocusIfIdle()
        }
    }

    // Keyboard shortcuts and arrow-key scrolling start at the first responder, so, as in Safari,
    // the page takes the focus whenever nothing else in the window has it. (Shortcuts typed with
    // nothing focused start at the window, which passes the browser's commands on.)
    func takeFocusIfIdle() {
        guard view.window != nil, presentedViewController == nil,
              let webView = displayedWebView, webView.window != nil else { return }
        let current = UIResponder.current
        if current == nil || current is UIWindow {
            webView.becomeFirstResponder()
        }
    }

    // MARK: - Setup

    /// Wide windows keep every button in the top bar with the tab strip below it. Narrow windows
    /// (Slide Over, small Stage Manager windows) move the buttons to a bottom toolbar and hide the strip.
    private func applyWidthLayout() {
        navigationItem.style = .browser
        navigationItem.titleView = addressField
        navigationItem.leftItemsSupplementBackButton = true
        let compact = traitCollection.horizontalSizeClass == .compact
        let erase: [UIBarButtonItem] = model.isPrivate ? [eraseButton] : []
        let downloads: [UIBarButtonItem] = services.downloads.items.isEmpty ? [] : [downloadsButton]
        if compact {
            navigationItem.leftBarButtonItems = []
            navigationItem.rightBarButtonItems = [moreButton] + downloads + erase
            toolbarItems = [
                backButton, .flexibleSpace(), forwardButton, .flexibleSpace(), shareButton, .flexibleSpace(),
                newTabButton, .flexibleSpace(), tabsButton,
            ]
        } else {
            toolbarItems = []
            navigationItem.leftBarButtonItems = [backButton, forwardButton]
            navigationItem.rightBarButtonItems = [moreButton, tabsButton, newTabButton, shareButton] + downloads + erase
        }
        navigationController?.setToolbarHidden(!compact, animated: false)
        tabStripHeight?.constant = compact ? 0 : 38
        tabStrip.isHidden = compact
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyWidthLayout()
    }

    private func configureLayout() {
        for subview in [tabStrip, contentView, progressView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        progressView.isHidden = true
        let height = tabStrip.heightAnchor.constraint(equalToConstant: 38)
        tabStripHeight = height
        NSLayoutConstraint.activate([
            height,
            tabStrip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        addressField.onShield = { [weak self] source in self?.showShield(from: source) }
        addressField.onMedia = { [weak self] source in self?.showMediaPicker(from: source) }
        addressField.onTextChange = { [weak self] text in self?.showSuggestions(for: text) }
        addressField.editingTextProvider = { [weak self] url in
            guard let self, let url else { return nil }
            return self.services.searchEngines.defaultEngine.searchTerms(in: url)
        }
        addressField.completionProvider = { [weak self] typed in
            self?.domainCompletion().completion(for: typed)
        }
        addressField.onEditingEnded = { [weak self] in
            self?.hideSuggestions()
            // After the next run loop: tapping into the page hands the focus over first.
            DispatchQueue.main.async { self?.takeFocusIfIdle() }
        }
        tabStrip.onSelect = { [weak self] tab in self?.model.select(tab) }
        tabStrip.onClose = { [weak self] tab in self?.model.close(tab) }
        tabStrip.onMove = { [weak self] from, to in self?.model.moveTab(from: from, to: to) }
        tabStrip.onToggleMute = { tab in tab.setMuted(!tab.isMuted) }
        tabStrip.menuProvider = { [weak self] tab in self?.menu(for: tab) }
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
            removeDisplayedWebView()
            showStartPage(isPrivate: model.isPrivate)
            return
        }

        tab.$showsStartPage
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] showsStartPage in
                guard let self, let tab else { return }
                if showsStartPage {
                    self.removeDisplayedWebView()
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
                self?.refreshShield()
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
        tab.$detectedMedia
            .receive(on: RunLoop.main)
            .sink { [weak self] media in
                self?.addressField.updateMedia(count: media.count, downloadable: media.contains(where: \.isDownloadable))
            }
            .store(in: &tabObservers)
    }

    /// Takes the shown page off screen; its tab keeps the web view for when it's shown again.
    private func removeDisplayedWebView() {
        displayedWebView?.removeFromSuperview()
        displayedWebView = nil
    }

    private func display(_ webView: WKWebView, for tab: TabModel) {
        if displayedWebView !== webView || webView.superview !== contentView {
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
        applyWidthLayout()
    }

    // MARK: - Suggestions

    private lazy var topDomains: [String] = {
        guard let url = Bundle.main.url(forResource: "topdomains", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()

    private func domainCompletion() -> DomainCompletion {
        let preferences = services.preferences
        return DomainCompletion(
            topDomains: topDomains, customDomains: preferences.customAutocompleteDomains,
            usesTopDomains: preferences.autocompleteTopSites, usesCustomDomains: preferences.autocompleteCustomSites)
    }

    private func showSuggestions(for text: String) {
        suggestions.onChange = { [weak self] in self?.updateSuggestionsPanel() }
        suggestions.update(query: text)
        updateSuggestionsPanel()
    }

    /// Shows the suggestions panel while there's something in it. Search suggestions arrive from
    /// the network after typing, so this also runs when they come in.
    private func updateSuggestionsPanel() {
        let hasContent = suggestions.hasContent
        if suggestionsHost == nil && hasContent && addressField.isEditing {
            let host = UIHostingController(rootView: SuggestionsView(
                model: suggestions, favicons: services.favicons, preferences: services.preferences,
                onSelect: { [weak self] suggestion in self?.choose(suggestion) },
                onSearch: { [weak self] query in
                    self?.addressField.resignFirstResponder()
                    self?.model.open(input: query)
                },
                onFindInPage: { [weak self] query in self?.find(query) },
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
            // VoiceOver (and UI tests) should only see the suggestions, not the page under them.
            host.view.accessibilityViewIsModal = true
            suggestionsHost = host
        }
        suggestionsHost?.view.isHidden = !hasContent
    }

    /// Opens Find on Page with `query` already filled in.
    private func find(_ query: String) {
        addressField.resignFirstResponder()
        guard let interaction = displayedWebView?.findInteraction else { return }
        interaction.presentFindNavigator(showingReplace: false)
        interaction.searchText = query
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

    /// The long-press menu for a tab in the strip.
    private func menu(for tab: TabModel) -> UIMenu {
        var actions: [UIMenuElement] = []
        if !tab.isPrivate {
            let store = services.tabStore
            var targets = ([model.defaultGroup] + store.namedGroups).filter { $0 !== model.normalGroup }
            targets = targets.filter { store.window(showing: $0) == nil || $0.title != nil }
            var moveItems: [UIMenuElement] = targets.map { group in
                UIAction(title: group.title ?? "This Window's Tabs",
                         image: UIImage(systemName: group.title == nil ? "square.on.square" : "folder")) { [weak self] _ in
                    self?.model.move(tab, to: group)
                }
            }
            moveItems.append(UIAction(title: "New Tab Group…", image: UIImage(systemName: "folder.badge.plus")) {
                [weak self] _ in self?.moveToNewGroup(tab)
            })
            actions.append(UIMenu(title: "Move to Tab Group", image: UIImage(systemName: "folder"), children: moveItems))
        }
        actions.append(UIAction(title: "Duplicate Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            self?.model.duplicate(tab)
        })
        if let url = tab.url {
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            })
        }
        actions.append(UIAction(title: tab.isMuted ? "Unmute Tab" : "Mute Tab",
                                image: UIImage(systemName: tab.isMuted ? "speaker.wave.2" : "speaker.slash")) { _ in
            tab.setMuted(!tab.isMuted)
        })
        let closing = UIMenu(options: .displayInline, children: [
            UIAction(title: "Close Other Tabs", image: UIImage(systemName: "xmark.square")) { [weak self] _ in
                self?.model.closeOtherTabs(than: tab)
            },
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.model.close(tab)
            },
        ])
        return UIMenu(children: actions + [closing])
    }

    private func moveToNewGroup(_ tab: TabModel) {
        let alert = UIAlertController(title: "New Tab Group", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Name"
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text ?? ""
            let group = self.services.tabStore.makeGroup(title: name.isEmpty ? "Tab Group" : name)
            self.model.move(tab, to: group)
        })
        present(alert, animated: true)
    }

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
            UIAction(title: "Downloads", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.showDownloads()
            },
            UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.showFiles()
            },
        ]))
        sections.append(UIMenu(options: .displayInline, children: [
            model.isPrivate
                ? UIAction(title: "Erase Private Browsing", image: UIImage(systemName: "trash"), attributes: .destructive) {
                    [weak self] _ in self?.erasePrivateBrowsing()
                }
                : UIAction(title: "Clear Browsing Data…", image: UIImage(systemName: "trash")) { [weak self] _ in
                    self?.showClearBrowsingData()
                },
            UIAction(title: "Settings", image: UIImage(systemName: "gear")) { [weak self] _ in
                self?.showSettings()
            },
        ]))
        return sections
    }

    // MARK: - Downloads

    private func observeDownloads() {
        let downloads = services.downloads
        downloads.$items
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWidthLayout() }
            .store(in: &modelObservers)
        downloads.$overallProgress.combineLatest(downloads.$runningCount)
            .receive(on: RunLoop.main)
            .sink { [weak self] progress, running in
                self?.downloadsRing.progress = running > 0 ? (progress ?? 0) : nil
            }
            .store(in: &modelObservers)
        downloads.didStart
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                guard let self, self.view.window?.isKeyWindow == true, !self.services.preferences.confirmDownloads else { return }
                Toast.show("Downloading \(item.record.fileName)", systemImage: "arrow.down.circle", in: self.view)
            }
            .store(in: &modelObservers)
        downloads.didFinish
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                guard let self, self.view.window?.isKeyWindow == true else { return }
                self.downloadsRing.bounce()
                Toast.show("Downloaded \(item.record.fileName)", systemImage: "checkmark.circle", in: self.view)
            }
            .store(in: &modelObservers)
    }

    /// Shows the downloads: from the toolbar button when it's there, otherwise in the sidebar.
    func showDownloads() {
        if navigationItem.rightBarButtonItems?.contains(downloadsButton) == true {
            showDownloadsPopover()
        } else {
            showLibrary(.downloads)
        }
    }

    private func showDownloadsPopover() {
        guard presentedViewController == nil else { return }
        let list = UIHostingController(rootView: DownloadsView(
            manager: services.downloads, actions: downloadActions(dismissingFirst: true)))
        list.title = "Downloads"
        let navigation = UINavigationController(rootViewController: list)
        navigation.modalPresentationStyle = .popover
        navigation.preferredContentSize = CGSize(width: 440, height: 560)
        navigation.popoverPresentationController?.sourceItem = downloadsButton
        present(navigation, animated: true)
    }

    /// What the Downloads list can ask of this window. From a popover or sheet, that closes first.
    func downloadActions(dismissingFirst: Bool) -> DownloadActions {
        let run: (@escaping () -> Void) -> Void = { [weak self] action in
            guard let self else { return }
            if dismissingFirst, self.presentedViewController != nil {
                self.dismiss(animated: true, completion: action)
            } else {
                action()
            }
        }
        return DownloadActions(
            openFile: { [weak self] item in run { self?.openDownloadedFile(item) } },
            share: { [weak self] item in run { self?.shareDownloadedFile(item) } },
            showInFiles: { [weak self] item in run { self?.showFiles(at: item.fileURL.deletingLastPathComponent()) } },
            openPage: { [weak self] url in run { self?.model.open(url) } },
            presenter: { [weak self] in self },
            isPrivate: { [weak self] in self?.model.isPrivate ?? false })
    }

    private func openDownloadedFile(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            Toast.show("The file was moved or deleted", systemImage: "exclamationmark.triangle", in: view)
            return
        }
        openFile(at: item.fileURL)
    }

    private func shareDownloadedFile(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            Toast.show("The file was moved or deleted", systemImage: "exclamationmark.triangle", in: view)
            return
        }
        PageActions.share(items: [item.fileURL], from: self, sourceView: displayedWebView ?? view)
    }

    // MARK: - Music

    private var miniPlayerHost: UIHostingController<MiniPlayerView>?

    private func observeAudio() {
        services.audio.$queue
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] empty in self?.setMiniPlayerVisible(!empty) }
            .store(in: &modelObservers)
    }

    private func setMiniPlayerVisible(_ visible: Bool) {
        if visible, miniPlayerHost == nil {
            let host = UIHostingController(rootView: MiniPlayerView(audio: services.audio) { [weak self] in
                self?.showAudioPlayer()
            })
            host.sizingOptions = .intrinsicContentSize
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            let fill = host.view.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
            fill.priority = .defaultHigh
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                host.view.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
                fill,
                host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            ])
            host.didMove(toParent: self)
            miniPlayerHost = host
        } else if !visible, let host = miniPlayerHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            miniPlayerHost = nil
        }
    }

    func showAudioPlayer() {
        let player = UIHostingController(rootView: AudioPlayerView(audio: services.audio, playlists: services.playlists))
        player.modalPresentationStyle = .formSheet
        player.preferredContentSize = CGSize(width: 540, height: 780)
        topController.present(player, animated: true)
    }

    // MARK: - Files

    /// Opens the file manager, at `folder` if given.
    func showFiles(at folder: URL? = nil) {
        let present = { [weak self] in
            guard let self else { return }
            let files = UIHostingController(rootView: FilesView(
                files: self.services.files, actions: self.fileActions(), startFolder: folder))
            files.modalPresentationStyle = .pageSheet
            self.present(files, animated: true)
        }
        if presentedViewController != nil {
            dismiss(animated: true, completion: present)
        } else {
            present()
        }
    }

    func fileActions() -> FileActions {
        FileActions(
            open: { [weak self] item, siblings in self?.openFile(item, among: siblings) },
            share: { [weak self] urls in self?.shareFiles(urls) },
            export: { [weak self] urls in
                self?.topController.present(UIDocumentPickerViewController(forExporting: urls, asCopy: true), animated: true)
            },
            saveToPhotos: { [weak self] urls in self?.saveFilesToPhotos(urls) },
            openPage: { [weak self] url in
                self?.dismiss(animated: true) { self?.model.open(url) }
            },
            sourcePage: { [weak self] url in self?.services.downloads.sourcePage(forFile: url) },
            playAudio: { [weak self] urls in
                guard let self else { return }
                self.services.audio.play(urls)
                self.showAudioPlayer()
            },
            addToPlaylist: { [weak self] urls in
                guard let self else { return }
                let picker = UIHostingController(rootView: AddToPlaylistView(
                    urls: urls, playlists: self.services.playlists, files: self.services.files))
                picker.modalPresentationStyle = .formSheet
                self.topController.present(picker, animated: true)
            },
            trim: { [weak self] url in
                guard let self else { return }
                let trimmer = UIHostingController(rootView: VideoTrimView(url: url, files: self.services.files))
                trimmer.modalPresentationStyle = .pageSheet
                self.topController.present(trimmer, animated: true)
            },
            close: { [weak self] in self?.dismiss(animated: true) })
    }

    /// The controller on top, for presenting over the file manager or a popover.
    var topController: UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Images open in the image viewer with the folder's other images, PDFs in the PDF viewer,
    /// music and video in the players (VLC for formats the system player can't open), everything
    /// else in Quick Look.
    private func openFile(_ item: FileItem, among siblings: [FileItem]) {
        if item.isImage && ImageLoader.canShow(item.url) {
            let images = siblings.filter { $0.isImage && ImageLoader.canShow($0.url) }.map(\.url)
            let urls = images.contains(item.url) ? images : [item.url]
            let viewer = ImageViewerController(
                urls: urls, index: urls.firstIndex(of: item.url) ?? 0, files: services.files, preferences: services.preferences)
            topController.present(viewer, animated: true)
        } else if item.isAudio && item.isPlayableMedia {
            let songs = siblings.filter { $0.isAudio && $0.isPlayableMedia }.map(\.url)
            let urls = songs.contains(item.url) ? songs : [item.url]
            services.audio.play(urls, startAt: urls.firstIndex(of: item.url) ?? 0)
            showAudioPlayer()
        } else if item.isMovie && item.isPlayableMedia {
            let videos = siblings.filter { $0.isMovie && $0.isPlayableMedia }.map(\.url)
            let urls = videos.contains(item.url) ? videos : [item.url]
            VideoPlayback(
                urls: urls, index: urls.firstIndex(of: item.url) ?? 0, preferences: services.preferences,
                positions: services.playbackPositions
            ).present(from: topController)
        } else if VLCPlayerViewController.canPlay(item.url) {
            // Formats the system player can't open play in VLC, with the folder's others of that kind.
            let others = siblings.filter { !$0.isPlayableMedia && VLCPlayerViewController.canPlay($0.url) }.map(\.url)
            let urls = others.contains(item.url) ? others : [item.url]
            topController.present(
                VLCPlayerViewController(
                    urls: urls, index: urls.firstIndex(of: item.url) ?? 0, positions: services.playbackPositions),
                animated: true)
        } else if item.contentType?.conforms(to: .pdf) == true {
            let viewer = UINavigationController(
                rootViewController: PDFViewerController(url: item.url, preferences: services.preferences))
            viewer.modalPresentationStyle = .fullScreen
            topController.present(viewer, animated: true)
        } else {
            let urls = siblings.contains(item) ? siblings.map(\.url) : [item.url]
            let index = urls.firstIndex(of: item.url) ?? 0
            topController.present(FilePreviewController(fileURLs: urls, index: index), animated: true)
        }
    }

    /// Opens a file at `url` the way the file manager would, with the other files in its folder.
    func openFile(at url: URL) {
        guard let item = FileItem(url: url) else { return }
        let siblings = services.files.contents(of: url.deletingLastPathComponent())
            .filter { !$0.isDirectory }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        openFile(item, among: siblings)
    }

    private func shareFiles(_ urls: [URL]) {
        let top = topController
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private func saveFilesToPhotos(_ urls: [URL]) {
        Task {
            do {
                try await PhotoLibrary.save(urls)
                Toast.show(urls.count == 1 ? "Saved to Photos" : "Saved \(urls.count) items to Photos",
                           systemImage: "photo", in: topController.view)
            } catch {
                Toast.show(error.localizedDescription, systemImage: "exclamationmark.triangle", in: topController.view)
            }
        }
    }

    /// A file opened in Browser from another app: it's copied into Downloads (files already in
    /// Browser's folders are just shown).
    func importIncomingFile(_ url: URL) {
        let files = services.files
        if files.isSameOrInside(url, files.root) {
            showFiles(at: url.deletingLastPathComponent())
            return
        }
        let downloads = files.root.appendingPathComponent("Downloads", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let copied = try files.importFiles([url], into: downloads)
            showFiles(at: downloads)
            if let name = copied.first?.lastPathComponent {
                Toast.show("Saved \(name) to Downloads", systemImage: "square.and.arrow.down", in: view)
            }
        } catch {
            Toast.show(error.localizedDescription, systemImage: "exclamationmark.triangle", in: view)
        }
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
            let overview = TabOverviewViewController(model: self.model)
            overview.onDismiss = { [weak self] in self?.takeFocusIfIdle() }
            self.present(overview, animated: true)
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

    private func refreshShield() {
        guard let tab = model.selectedTab else { return }
        let protected = services.preferences.trackingProtectionEnabled
            && services.siteSettings.settings(for: tab.url).trackingProtectionDisabled != true
        addressField.updateShield(protected: protected, secure: tab.hasOnlySecureContent || tab.url?.scheme != "http")
    }

    private func showShield(from source: UIView) {
        guard let tab = model.selectedTab else { return }
        if let presented = presentedViewController {
            Log.event("Shield not shown: already presenting \(type(of: presented))")
            return
        }
        let shield = ShieldView(tab: tab, services: services) { [weak self] in
            ContentBlocker.shared.settingsChanged()
            self?.refreshShield()
        }
        let host = UIHostingController(rootView: shield)
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .popover
        host.popoverPresentationController?.sourceView = source
        host.popoverPresentationController?.sourceRect = source.bounds
        host.popoverPresentationController?.permittedArrowDirections = [.up]
        present(host, animated: true)
    }

    /// Firefox Focus's Erase: closes private tabs everywhere, drops the private data store, then
    /// shows a fresh private tab. The old screen slides away as it fades.
    func erasePrivateBrowsing() {
        guard let window = view.window else { return }
        let snapshot = window.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            window.addSubview(snapshot)
        }
        EraseService.erasePrivateBrowsing(services: services)
        model.newTab(isPrivate: true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let snapshot {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
                snapshot.transform = CGAffineTransform(translationX: 0, y: window.bounds.height * 0.3).scaledBy(x: 0.9, y: 0.9)
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }
        Toast.show("Browsing history cleared", systemImage: "trash", in: view)
        DispatchQueue.main.async { [weak self] in
            self?.addressField.beginEditingAddress()
        }
    }

    func showClearBrowsingData() {
        guard presentedViewController == nil else { return }
        let services = self.services
        let clearView = ClearDataView(onClear: { [weak self] request in
            self?.dismiss(animated: true)
            Task {
                await EraseService.clear(request, services: services)
                if let self {
                    Toast.show("Browsing data cleared", systemImage: "checkmark", in: self.view)
                }
            }
        }, onCancel: { [weak self] in
            self?.dismiss(animated: true)
        })
        let host = UIHostingController(rootView: clearView)
        host.modalPresentationStyle = .formSheet
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

    func showSettings() {
        guard presentedViewController == nil else { return }
        let settings = SettingsView(
            preferences: services.preferences, sites: services.siteSettings,
            onClearData: { [weak self] in
                self?.dismiss(animated: true) { self?.showClearBrowsingData() }
            },
            onDone: { [weak self] in
                self?.dismiss(animated: true)
            })
        let host = UIHostingController(rootView: settings)
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
        guard let input, let target = BrowserWindowModel.url(for: input, engine: services.searchEngines.defaultEngine)
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

    func showImageMenu(_ url: URL, at point: CGPoint, in sourceView: UIView, from tab: TabModel) {
        guard presentedViewController == nil else { return }
        let sheet = UIAlertController(title: nil, message: url.lastPathComponent, preferredStyle: .actionSheet)
        let actions: [(String, () -> Void)] = [
            ("Open Image in New Tab", { [weak self] in self?.openInNewTab(url, from: tab, background: false, isPrivate: tab.isPrivate) }),
            ("Save to Photos", { [weak self] in self?.imageAction(.saveToPhotos, url: url, from: tab) }),
            ("Save to Downloads", { [weak self] in self?.imageAction(.download, url: url, from: tab) }),
            ("Copy Image", { [weak self] in self?.imageAction(.copy, url: url, from: tab) }),
            ("Share Image…", { [weak self] in self?.imageAction(.share, url: url, from: tab) }),
        ]
        for (title, action) in actions {
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in action() })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        present(sheet, animated: true)
    }

    func downloadLink(_ url: URL, from tab: TabModel) {
        services.downloads.download(url, from: tab)
    }

    func showVideoMenu(_ media: DetectedMedia, at point: CGPoint, in sourceView: UIView, from tab: TabModel) {
        guard presentedViewController == nil else { return }
        let media = named(media, in: tab)
        let isAudio = media.kind == .audio
        let message = media.isDownloadable ? media.suggestedFileName : unsaveableReason(media)
        let sheet = UIAlertController(title: nil, message: message, preferredStyle: .actionSheet)
        if media.isDownloadable {
            sheet.addAction(UIAlertAction(title: isAudio ? "Download Audio" : "Download Video", style: .default) { [weak self] _ in
                self?.downloadMedia(media, from: tab)
            })
        }
        if media.kind != .stream, !media.isProtected {
            sheet.addAction(UIAlertAction(title: "Play in Player", style: .default) { [weak self] _ in
                self?.playMedia(media, from: tab)
            })
        }
        if media.kind != .stream {
            sheet.addAction(UIAlertAction(title: isAudio ? "Copy Audio Address" : "Copy Video Address", style: .default) { [weak self] _ in
                self?.copyMediaAddress(media)
            })
        }
        if tab.detectedMedia.contains(where: { $0.url != media.url }) {
            sheet.addAction(UIAlertAction(title: "All Video and Audio on This Page…", style: .default) { [weak self] _ in
                guard let self else { return }
                self.showMediaPicker(from: self.addressField)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        }
        present(sheet, animated: true)
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
                    let downloads = services.downloads
                    let folder = downloads.defaultFolder(forFileNamed: image.filename, mimeType: image.type?.preferredMIMEType)
                    let file = try ImageActions.saveToDownloads(
                        image.data, filename: image.filename, type: image.type, folder: folder)
                    downloads.addSavedFile(file, folder: folder, sourceURL: url, pageURL: tab.url, isPrivate: tab.isPrivate)
                    Toast.show("Saved \(file.lastPathComponent) to \(folder)", systemImage: "arrow.down.doc", in: view)
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
    @objc func showSettingsCommand(_ sender: Any?) { showSettings() }
    @objc func showDownloadsCommand(_ sender: Any?) { showDownloads() }
    @objc func eraseCommand(_ sender: Any?) {
        if model.isPrivate { erasePrivateBrowsing() } else { showClearBrowsingData() }
    }

    /// ⌘1–⌘8 pick that tab, ⌘9 the last one (like Safari).
    @objc func selectTabCommand(_ sender: UICommand) {
        guard let number = sender.propertyList as? Int else { return }
        let tabs = model.activeGroup.tabs
        guard !tabs.isEmpty else { return }
        model.select(number == 9 ? tabs[tabs.count - 1] : tabs[min(number - 1, tabs.count - 1)])
    }

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
