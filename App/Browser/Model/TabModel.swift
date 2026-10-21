import BrowserCore
import Combine
import UIKit
import WebKit

/// What a tab needs from the window that shows it.
protocol TabModelDelegate: AnyObject {
    /// The page opened a new window (target=_blank or window.open). Return the web view to use,
    /// built from `configuration`, or nil to block it.
    func tab(_ tab: TabModel, createWebViewWith configuration: WKWebViewConfiguration,
             for navigationAction: WKNavigationAction) -> WKWebView?
    /// The page called window.close().
    func tabDidRequestClose(_ tab: TabModel)
    /// The view controller to present prompts from, or nil when the tab isn't on screen.
    func presenter(for tab: TabModel) -> UIViewController?
}

/// One browser tab. The web view is created lazily when the tab is first shown and can be
/// discarded to save memory; its URL and back/forward history are kept for restoring.
final class TabModel: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    weak var delegate: TabModelDelegate?

    @Published private(set) var url: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var estimatedProgress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var hasOnlySecureContent = false
    @Published private(set) var snapshot: UIImage?
    /// True while the tab has no page and shows the New Tab page instead.
    @Published private(set) var showsStartPage: Bool

    private(set) var webView: WKWebView?
    private(set) var lastActive: Date
    private var pendingInteractionState: Data?
    private var pendingURL: URL?
    private var needsReload = false
    private var webViewObservers: Set<AnyCancellable> = []

    /// Called when the tab's saved state changes (URL, title, history).
    var onStateChange: (() -> Void)?

    init(isPrivate: Bool, url: URL? = nil) {
        id = UUID()
        self.isPrivate = isPrivate
        lastActive = Date()
        pendingURL = url
        self.url = url
        showsStartPage = url == nil
        super.init()
    }

    /// A saved tab; its web view is created when the tab is first shown.
    init(snapshot saved: TabSnapshot) {
        id = saved.id
        isPrivate = false
        lastActive = saved.lastActive
        pendingURL = saved.url
        pendingInteractionState = saved.interactionState
        url = saved.url
        pageTitle = saved.title
        showsStartPage = saved.url == nil && saved.interactionState == nil
        super.init()
    }

    /// A tab for a popup window, using the web view WebKit asked for.
    init(isPrivate: Bool, popupWebView: WKWebView) {
        id = UUID()
        self.isPrivate = isPrivate
        lastActive = Date()
        showsStartPage = false
        super.init()
        attach(popupWebView)
    }

    var title: String {
        URLDisplay.tabTitle(pageTitle: pageTitle, url: url)
    }

    var hasLiveWebView: Bool {
        webView != nil
    }

    // MARK: - Web view lifecycle

    /// The web view to put on screen, created and restored if needed.
    func makeWebViewIfNeeded() -> WKWebView {
        if let webView {
            if needsReload {
                needsReload = false
                webView.reload()
            }
            return webView
        }
        let configuration = WebViewFactory.makeConfiguration(isPrivate: isPrivate)
        let webView = WebViewFactory.makeWebView(configuration: configuration)
        attach(webView)
        if let state = pendingInteractionState {
            webView.interactionState = state
        } else if let url = pendingURL {
            webView.load(URLRequest(url: url))
        }
        pendingInteractionState = nil
        pendingURL = nil
        return webView
    }

    /// Drops the web view to free memory, keeping what's needed to restore it.
    func discardWebView() {
        guard let webView else { return }
        pendingInteractionState = webView.interactionState as? Data
        pendingURL = webView.url ?? url
        detach(webView)
        self.webView = nil
        Log.tabs.info("Discarded web view of a background tab")
    }

    /// Tears the web view down for good (the tab is closing).
    func close() {
        if let webView {
            detach(webView)
            webView.stopLoading()
        }
        webView = nil
    }

    func markActive() {
        lastActive = Date()
    }

    private func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe(webView)
    }

    private func detach(_ webView: WKWebView) {
        webViewObservers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func observe(_ webView: WKWebView) {
        webViewObservers.removeAll()
        webView.publisher(for: \.url)
            .sink { [weak self] url in
                guard let self, let url else { return }
                self.url = url
                self.onStateChange?()
            }
            .store(in: &webViewObservers)
        webView.publisher(for: \.title)
            .sink { [weak self] title in
                guard let self else { return }
                self.pageTitle = title ?? ""
                self.onStateChange?()
            }
            .store(in: &webViewObservers)
        webView.publisher(for: \.estimatedProgress)
            .sink { [weak self] value in self?.estimatedProgress = value }
            .store(in: &webViewObservers)
        webView.publisher(for: \.isLoading)
            .sink { [weak self] value in self?.isLoading = value }
            .store(in: &webViewObservers)
        webView.publisher(for: \.canGoBack)
            .sink { [weak self] value in self?.canGoBack = value }
            .store(in: &webViewObservers)
        webView.publisher(for: \.canGoForward)
            .sink { [weak self] value in self?.canGoForward = value }
            .store(in: &webViewObservers)
        webView.publisher(for: \.hasOnlySecureContent)
            .sink { [weak self] value in self?.hasOnlySecureContent = value }
            .store(in: &webViewObservers)
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        showsStartPage = false
        self.url = url
        makeWebViewIfNeeded().load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        guard let webView else {
            if let url = pendingURL { load(url) }
            return
        }
        if webView.url == nil, let url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    /// The process rendering this tab crashed; reload when the tab is next shown.
    func markNeedsReload() {
        needsReload = true
    }

    // MARK: - Snapshots

    func captureSnapshot() {
        guard let webView, webView.window != nil, !showsStartPage else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: 480)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image {
                self?.snapshot = image
            }
        }
    }

    func makeSnapshot() -> TabSnapshot {
        let state = (webView?.interactionState as? Data) ?? pendingInteractionState
        return TabSnapshot(id: id, url: url, title: pageTitle, interactionState: state, lastActive: lastActive)
    }
}
