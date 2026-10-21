import BrowserCore
import Combine
import UIKit
import WebKit

/// What a tab needs from the window that shows it.
protocol TabModelDelegate: ContextMenuHandler {
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
    /// When WebKit last asked for a long-press menu (the image long-press fallback skips then).
    var lastContextMenuDate = Date.distantPast
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
    /// True while the page plays media with sound (or would, if the tab weren't muted).
    @Published private(set) var isPlayingAudio = false
    @Published private(set) var isMuted = false
    /// Trackers blocked on the current page, by category.
    @Published private(set) var trackerCounts = TrackerCounts()

    private(set) var webView: WKWebView?
    private(set) var lastActive: Date
    private var pendingInteractionState: Data?
    private var pendingURL: URL?
    private var needsReload = false
    private var webViewObservers: Set<AnyCancellable> = []
    private var mediaFrames: [String: Bool] = [:]

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
    init(snapshot saved: TabSnapshot, isPrivate: Bool = false) {
        id = saved.id
        self.isPrivate = isPrivate
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
        // The first page waits until tracker blocking is in place.
        ContentBlocker.shared.whenReady { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else { return }
            if let state = self.pendingInteractionState {
                webView.interactionState = state
            } else if let url = self.pendingURL {
                webView.load(URLRequest(url: url))
            }
            self.pendingInteractionState = nil
            self.pendingURL = nil
        }
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
        UserScripts.install(in: webView.configuration.userContentController)
        ScriptMessageRouter.shared.register(self, for: webView)
        ContentBlocker.shared.whenReady { [weak webView] in
            if let webView {
                ContentBlocker.shared.apply(to: webView.configuration.userContentController)
            }
        }
        webView.customUserAgent = effectiveUserAgent(for: pendingURL ?? url)
        addImageLongPress(to: webView)
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
                if !self.isPrivate, let url = self.url, let title, !title.isEmpty {
                    AppServices.shared.history.updateTitle(title, for: url)
                }
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
        let webView = makeWebViewIfNeeded()
        ContentBlocker.shared.whenReady { [weak webView] in
            webView?.load(URLRequest(url: url))
        }
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

    // MARK: - Site settings

    /// The user agent for `url`: the site's own choice, else the default, else WebKit's (nil).
    func effectiveUserAgent(for url: URL?) -> String? {
        let services = AppServices.shared
        let site = services.siteSettings.settings(for: url)
        if let agent = site.userAgent {
            return agent.string(custom: site.customUserAgent ?? services.preferences.customUserAgent)
        }
        return services.preferences.defaultUserAgent.string(custom: services.preferences.customUserAgent)
    }

    /// The layout WebKit should request for `url`.
    func contentMode(for url: URL?) -> WKWebpagePreferences.ContentMode {
        let services = AppServices.shared
        let layout = services.siteSettings.settings(for: url).layout ?? services.preferences.defaultLayout
        // .recommended gives iPad Safari's desktop-class layout.
        return layout == .mobile ? .mobile : .recommended
    }

    var currentZoom: Double {
        Double(webView?.pageZoom ?? 1)
    }

    /// Applies the site's zoom (or the default) after a page commits.
    func applyPageZoom() {
        guard let webView else { return }
        let services = AppServices.shared
        let zoom = services.siteSettings.settings(for: url).zoom ?? services.preferences.defaultZoom
        if abs(Double(webView.pageZoom) - zoom) > 0.001 {
            webView.pageZoom = CGFloat(zoom)
        }
    }

    func setZoom(_ zoom: Double, remember: Bool) {
        webView?.pageZoom = CGFloat(zoom)
        guard remember else { return }
        let defaultZoom = AppServices.shared.preferences.defaultZoom
        AppServices.shared.siteSettings.update(url) { settings in
            settings.zoom = abs(zoom - defaultZoom) < 0.001 ? nil : zoom
        }
    }

    func setLayout(_ layout: SiteLayout) {
        let defaultLayout = AppServices.shared.preferences.defaultLayout
        AppServices.shared.siteSettings.update(url) { settings in
            settings.layout = layout == defaultLayout ? nil : layout
        }
        webView?.reloadFromOrigin()
    }

    func setUserAgentOverride(_ agent: UserAgent?) {
        AppServices.shared.siteSettings.update(url) { settings in
            settings.userAgent = agent
        }
        webView?.customUserAgent = effectiveUserAgent(for: url)
        webView?.reloadFromOrigin()
    }

    // MARK: - Media

    func handleScriptMessage(name: String, body: Any) {
        if name == ScriptMessageRouter.trackersHandler {
            countTracker(body)
            return
        }
        guard name == ScriptMessageRouter.mediaHandler, let info = body as? [String: Any],
              let frame = info["frame"] as? String
        else { return }
        let playing = info["playing"] as? Bool ?? false
        let audible = info["audible"] as? Bool ?? false
        mediaFrames[frame] = playing && (audible || isMuted)
        let anyPlaying = mediaFrames.values.contains(true)
        if anyPlaying != isPlayingAudio {
            isPlayingAudio = anyPlaying
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        guard let webView else { return }
        Self.setPageMuted(muted, in: webView)
        webView.evaluateJavaScript(
            "window.__browserSetMuted && window.__browserSetMuted(\(muted))", in: nil, in: UserScripts.world,
            completionHandler: nil)
    }

    /// Counts a request the page made if it's a tracker that's being blocked here.
    private func countTracker(_ body: Any) {
        guard let info = body as? [String: Any], let address = info["url"] as? String,
              let resource = URL(string: address), let matcher = ContentBlocker.shared.matcher,
              let category = matcher.category(for: resource, on: url),
              ContentBlocker.shared.isBlocking(category, on: url)
        else { return }
        trackerCounts.add(category)
        AppServices.shared.preferences.addBlockedTrackers(1)
    }

    /// A new page started: forget the old page's media and tracker counts.
    func resetMediaState() {
        trackerCounts = TrackerCounts()
        mediaFrames.removeAll()
        if isPlayingAudio {
            isPlayingAudio = false
        }
    }

    /// WebKit's private -_setPageMuted:, which also silences Web Audio. Used only when present.
    private static func setPageMuted(_ muted: Bool, in webView: WKWebView) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        typealias SetMuted = @convention(c) (AnyObject, Selector, Int) -> Void
        let implementation = webView.method(for: selector)
        unsafeBitCast(implementation, to: SetMuted.self)(webView, selector, muted ? 1 : 0)
    }

    // MARK: - Page loaded

    /// Records history, fetches the favicon and re-applies muting once a page has loaded.
    func pageDidFinishLoading() {
        guard let webView, let url = webView.url else { return }
        if !isPrivate {
            AppServices.shared.history.recordVisit(to: url, title: pageTitle)
        }
        if isMuted {
            setMuted(true)
        }
        let isPrivate = self.isPrivate
        Task {
            let result = try? await webView.callAsyncJavaScript(
                "return " + UserScripts.iconLinksScript, arguments: [:], in: nil, contentWorld: UserScripts.world)
            let candidates = (result as? [String])?.compactMap(URL.init(string:)) ?? []
            AppServices.shared.favicons.fetchIcon(for: url, candidates: candidates, isPrivate: isPrivate)
        }
    }

    // MARK: - Snapshots

    func captureSnapshot(completion: (() -> Void)? = nil) {
        guard let webView, webView.window != nil, !showsStartPage else {
            completion?()
            return
        }
        let configuration = WKSnapshotConfiguration()
        let width = webView.bounds.width
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: min(webView.bounds.height, width * 0.8))
        configuration.snapshotWidth = NSNumber(value: 480)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image {
                self?.snapshot = image
            }
            completion?()
        }
    }

    func makeSnapshot() -> TabSnapshot {
        let state = (webView?.interactionState as? Data) ?? pendingInteractionState
        return TabSnapshot(id: id, url: url, title: pageTitle, interactionState: state, lastActive: lastActive)
    }
}
