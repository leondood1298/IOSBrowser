import BrowserCore
import Combine
import UIKit
import WebKit

/// The tabs of one window: its normal group (saved) and its private group (memory only),
/// plus which one is showing and which tab is selected.
final class BrowserWindowModel: ObservableObject {
    let services: AppServices
    let normalGroup: TabGroup
    let privateGroup: TabGroup

    @Published private(set) var isPrivate = false
    @Published private(set) var selectedTab: TabModel?
    /// Closed tabs, newest first, for ⇧⌘T. Private ones are dropped when private browsing ends.
    @Published private(set) var recentlyClosed: [ClosedTab] = []

    struct ClosedTab: Identifiable {
        let snapshot: TabSnapshot
        let isPrivate: Bool
        var id: UUID { snapshot.id }
        var title: String { URLDisplay.tabTitle(pageTitle: snapshot.title, url: snapshot.url) }
    }

    /// Receives prompts and popup requests from every tab in this window.
    weak var tabDelegate: TabModelDelegate? {
        didSet { allTabs.forEach { $0.delegate = tabDelegate } }
    }

    init(services: AppServices = .shared, restoringGroupID: UUID?) {
        self.services = services
        if let id = restoringGroupID, let group = services.tabStore.group(withID: id) {
            normalGroup = group
        } else {
            normalGroup = services.tabStore.makeGroup()
        }
        privateGroup = TabGroup(isPrivate: true)
        for tab in normalGroup.tabs {
            adopt(tab)
        }
        if normalGroup.tabs.isEmpty {
            newTab()
        } else {
            select(normalGroup.selectedTab ?? normalGroup.tabs[normalGroup.tabs.count - 1])
        }
    }

    var activeGroup: TabGroup {
        isPrivate ? privateGroup : normalGroup
    }

    var allTabs: [TabModel] {
        normalGroup.tabs + privateGroup.tabs
    }

    // MARK: - Selecting

    func select(_ tab: TabModel) {
        let group = tab.isPrivate ? privateGroup : normalGroup
        guard group.index(of: tab) != nil else { return }
        if isPrivate != tab.isPrivate {
            isPrivate = tab.isPrivate
        }
        group.selectedTabID = tab.id
        selectedTab = tab
    }

    func selectTab(at index: Int) {
        let tabs = activeGroup.tabs
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectNextTab(offset: Int) {
        let tabs = activeGroup.tabs
        guard let current = selectedTab, let index = activeGroup.index(of: current), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Switches between normal and private tabs, creating a tab if that side has none.
    func setPrivate(_ value: Bool) {
        let group = value ? privateGroup : normalGroup
        if let tab = group.selectedTab ?? group.tabs.last {
            select(tab)
        } else {
            newTab(isPrivate: value)
        }
    }

    // MARK: - Opening and closing

    /// Opens a tab. New tabs go to the end unless `after` is given; links opened from a page
    /// go right after that page's tab.
    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool? = nil, after: TabModel? = nil, select shouldSelect: Bool = true) -> TabModel {
        let makePrivate = isPrivate ?? self.isPrivate
        let tab = TabModel(isPrivate: makePrivate, url: url)
        insert(tab, after: after)
        if shouldSelect {
            select(tab)
        }
        return tab
    }

    /// A tab for a popup, using the web view WebKit created from `configuration`.
    func openPopup(configuration: WKWebViewConfiguration, from opener: TabModel) -> WKWebView {
        let webView = WebViewFactory.makeWebView(configuration: configuration)
        let tab = TabModel(isPrivate: opener.isPrivate, popupWebView: webView)
        insert(tab, after: opener)
        select(tab)
        return webView
    }

    func close(_ tab: TabModel) {
        let group = tab.isPrivate ? privateGroup : normalGroup
        let wasSelected = selectedTab === tab
        guard let index = group.remove(tab) else { return }
        remember(tab)
        tab.close()
        WebViewBudget.shared.forget(tab)

        guard wasSelected else { return }
        if group.tabs.isEmpty {
            if tab.isPrivate {
                setPrivate(false)
            } else {
                newTab(isPrivate: false)
            }
        } else {
            select(group.tabs[min(index, group.tabs.count - 1)])
        }
    }

    func closeAllTabs(isPrivate closePrivate: Bool) {
        let group = closePrivate ? privateGroup : normalGroup
        for tab in group.tabs {
            if closePrivate {
                tab.close()
                WebViewBudget.shared.forget(tab)
                continue
            }
            remember(tab)
            tab.close()
            WebViewBudget.shared.forget(tab)
        }
        group.removeAll()
        if closePrivate {
            recentlyClosed.removeAll { $0.isPrivate }
            setPrivate(false)
        } else if !isPrivate {
            newTab(isPrivate: false)
        }
    }

    /// Reopens a closed tab with its history, after the selected tab.
    func reopen(_ closed: ClosedTab) {
        recentlyClosed.removeAll { $0.id == closed.id }
        let tab = TabModel(snapshot: closed.snapshot, isPrivate: closed.isPrivate)
        insert(tab, after: selectedTab?.isPrivate == closed.isPrivate ? selectedTab : nil)
        select(tab)
    }

    func reopenLastClosedTab() {
        if let last = recentlyClosed.first {
            reopen(last)
        }
    }

    private func remember(_ tab: TabModel) {
        guard tab.url != nil else { return }
        recentlyClosed.insert(ClosedTab(snapshot: tab.makeSnapshot(), isPrivate: tab.isPrivate), at: 0)
        if recentlyClosed.count > 20 {
            recentlyClosed.removeLast()
        }
    }

    func moveTab(from source: Int, to destination: Int) {
        activeGroup.move(from: source, to: destination)
    }

    /// Opens what the user typed: a URL, or a search with the chosen engine.
    func open(input: String, in tab: TabModel? = nil) {
        guard let url = Self.url(for: input, engine: services.preferences.searchEngine) else { return }
        open(url, in: tab)
    }

    func open(_ url: URL, in tab: TabModel? = nil) {
        guard let target = tab ?? selectedTab else {
            newTab(url: url)
            return
        }
        target.load(url)
    }

    static func url(for input: String, engine: SearchEngine) -> URL? {
        switch URIFixup.classify(input) {
        case .url(let url)?:
            return url
        case .search(let query)?:
            return engine.searchURL(for: query)
        case nil:
            return nil
        }
    }

    // MARK: - Helpers

    private func insert(_ tab: TabModel, after anchor: TabModel?) {
        let group = tab.isPrivate ? privateGroup : normalGroup
        let index = anchor.flatMap { group.index(of: $0) }.map { $0 + 1 }
        adopt(tab)
        group.insert(tab, at: index)
    }

    private func adopt(_ tab: TabModel) {
        tab.delegate = tabDelegate
        if !tab.isPrivate {
            tab.onStateChange = { [weak self] in self?.services.tabStore.scheduleSave() }
        }
    }
}
