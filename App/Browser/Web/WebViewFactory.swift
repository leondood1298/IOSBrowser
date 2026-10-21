import UIKit
import WebKit

/// Builds the web views for normal and private tabs.
enum WebViewFactory {
    static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate
            ? AppServices.shared.privateSession.dataStore
            : WKWebsiteDataStore.default()
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.ignoresViewportScaleLimits = true
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.defaultWebpagePreferences.preferredContentMode = .recommended

        let preferences = configuration.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = false  // pop-up blocker
        preferences.isFraudulentWebsiteWarningEnabled = true
        preferences.isElementFullscreenEnabled = true
        return configuration
    }

    /// Creates a web view from `configuration`, which may come from WebKit for a popup.
    static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.isInspectable = true
        webView.accessibilityIdentifier = "webView"
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak webView] action in
            webView?.reload()
            (action.sender as? UIRefreshControl)?.endRefreshing()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        return webView
    }

    /// Appended to WebKit's user agent so sites see the Safari version they expect,
    /// for example "Version/27.0 Safari/605.1.15".
    static var applicationNameForUserAgent: String {
        let parts = UIDevice.current.systemVersion.split(separator: ".")
        let major = parts.first.map(String.init) ?? "26"
        let minor = parts.count > 1 ? String(parts[1]) : "0"
        return "Version/\(major).\(minor) Safari/605.1.15"
    }
}
