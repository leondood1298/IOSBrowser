import BrowserCore
import UIKit
import WebKit

// MARK: - WKNavigationDelegate

extension TabModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        // <a download> links.
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }

        switch ExternalLinkPolicy.action(for: url) {
        case .load:
            guard isMainFrame else { return (allowPolicy(for: navigationAction), preferences) }
            preferences.preferredContentMode = contentMode(for: url)
            preferences.allowsContentJavaScript = !AppServices.shared.preferences.blockJavaScript
            // Each site can have its own user agent. It must be set before the request goes out,
            // so a mismatch re-issues the request with the right one (not for back/forward).
            let agent = effectiveUserAgent(for: url)
            let current = webView.customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
            if agent != current {
                webView.customUserAgent = agent
                let isGet = (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET"
                if navigationAction.navigationType != .backForward && isGet {
                    webView.load(navigationAction.request)
                    return (.cancel, preferences)
                }
            }
            return (allowPolicy(for: navigationAction), preferences)
        case .block:
            return (.cancel, preferences)
        case .openDirectly:
            guard isMainFrame else { return (.cancel, preferences) }
            await openExternally(url)
            return (.cancel, preferences)
        case .askToOpen(let app):
            guard isMainFrame else { return (.cancel, preferences) }
            if !AppServices.shared.preferences.askBeforeOpeningApps {
                await openExternally(url)
            } else if let presenter = delegate?.presenter(for: self),
                      await Prompts.confirm(
                        from: presenter, title: ExternalLinkPolicy.prompt(for: app), message: nil, confirm: "Open") {
                await openExternally(url)
            }
            return (.cancel, preferences)
        case .offerApp(let app):
            guard isMainFrame, navigationAction.navigationType == .linkActivated,
                  let presenter = delegate?.presenter(for: self)
            else { return (allowPolicy(for: navigationAction), preferences) }
            if await Prompts.confirm(
                from: presenter, title: ExternalLinkPolicy.prompt(for: app), message: nil,
                confirm: "Open App", cancel: "Stay Here") {
                await openExternally(url)
                return (.cancel, preferences)
            }
            return (allowPolicy(for: navigationAction), preferences)
        }
    }

    /// `.allow`, or `.allow` without trying universal links when links shouldn't open apps.
    private func allowPolicy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        guard !AppServices.shared.preferences.allowLinksToOpenApps,
              navigationAction.targetFrame?.isMainFrame ?? true
        else { return .allow }
        // WebKit's _WKNavigationActionPolicyAllowWithoutTryingAppLink (WKNavigationActionPolicyAllow + 2),
        // the value Firefox Focus uses to keep links in the browser.
        return WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
    }

    private func openExternally(_ url: URL) async {
        let opened = await UIApplication.shared.open(url)
        if !opened, let presenter = delegate?.presenter(for: self) {
            await Prompts.notice(from: presenter, title: "No app can open this link", message: url.absoluteString)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        // Files sent as attachments are downloaded from any frame; pages that can't be shown only
        // from the main frame (a frame with an odd type shouldn't start a download).
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased()
        if disposition?.hasPrefix("attachment") == true {
            return .download
        }
        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        AppServices.shared.downloads.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        AppServices.shared.downloads.adopt(download, from: self)
    }

    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        let handled = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM]
        guard handled.contains(method), let presenter = delegate?.presenter(for: self) else {
            return (.performDefaultHandling, nil)
        }
        guard let credential = await Prompts.httpLogin(
            from: presenter, host: challenge.protectionSpace.host, realm: challenge.protectionSpace.realm,
            failedBefore: challenge.previousFailureCount > 0)
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, credential)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        resetMediaState()
        applyPageZoom()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onStateChange?()
        captureSnapshot()
        pageDidFinishLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorPage(for: error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard !ErrorPage.shouldIgnore(domain: nsError.domain, code: nsError.code) else { return }
        Log.web.error("Navigation failed: \(nsError.domain, privacy: .public) \(nsError.code)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.event("Web content process terminated", category: "web")
        if webView.window != nil {
            webView.reload()
        } else {
            markNeedsReload()
        }
    }

    private func showErrorPage(for error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        guard !ErrorPage.shouldIgnore(domain: nsError.domain, code: nsError.code) else { return }
        Log.web.error("Load failed: \(nsError.domain, privacy: .public) \(nsError.code)")
        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url
        let content = ErrorPage.content(domain: nsError.domain, code: nsError.code, description: nsError.localizedDescription)
        let html = ErrorPage.html(content, failingURL: failingURL)
        if let failingURL, ["http", "https"].contains(failingURL.scheme?.lowercased() ?? "") {
            // Loads the page as if it came from the failing URL, so Reload and Back work normally.
            _ = webView.loadSimulatedRequest(URLRequest(url: failingURL), responseHTML: html)
        } else {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

// MARK: - WKUIDelegate

extension TabModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        delegate?.tab(self, createWebViewWith: configuration, for: navigationAction)
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabDidRequestClose(self)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        guard let presenter = delegate?.presenter(for: self) else { return }
        await Prompts.notice(from: presenter, title: Self.dialogTitle(for: frame), message: message)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        guard let presenter = delegate?.presenter(for: self) else { return false }
        return await Prompts.confirm(from: presenter, title: Self.dialogTitle(for: frame), message: message, confirm: "OK")
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let presenter = delegate?.presenter(for: self) else { return nil }
        return await Prompts.textInput(
            from: presenter, title: Self.dialogTitle(for: frame), message: prompt, defaultText: defaultText)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo
    ) async -> UIContextMenuConfiguration? {
        guard let handler = delegate else { return nil }
        var info: [String: Any]?
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.__browserContextInfo ? window.__browserContextInfo() : null;",
                arguments: [:], in: nil, contentWorld: UserScripts.world)
            info = result as? [String: Any]
        } catch {
            Log.event("Long-press: page script failed: \(error.localizedDescription)", category: "web")
        }
        let link = elementInfo.linkURL ?? (info?["link"] as? String).flatMap(URL.init(string:))
        let scriptImage = (info?["image"] as? String).flatMap(URL.init(string:))
        let webKitImage = scriptImage == nil ? Self.imageURL(of: elementInfo) : nil
        Log.event(
            "Long-press: link \(link != nil), page script \(info == nil ? "nothing" : "answered"), "
                + "image from script \(scriptImage != nil), from WebKit \(webKitImage != nil)",
            category: "web")
        return ContextMenus.configuration(
            link: link, image: scriptImage ?? webKitImage, linkTitle: info?["title"] as? String, tab: self,
            handler: handler)
    }

    /// The pressed image's address from WebKit's own element info (private API), for when the
    /// page script didn't see the touch, e.g. inside a frame.
    private static func imageURL(of elementInfo: WKContextMenuElementInfo) -> URL? {
        guard elementInfo.responds(to: NSSelectorFromString("_activatedElementInfo")),
              let activated = elementInfo.value(forKey: "_activatedElementInfo") as? NSObject,
              activated.responds(to: NSSelectorFromString("imageURL"))
        else { return nil }
        return activated.value(forKey: "imageURL") as? URL
    }

    func webView(
        _ webView: WKWebView,
        contextMenuForElement elementInfo: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let url = elementInfo.linkURL else { return }
        animator.addCompletion { [weak webView] in
            webView?.load(URLRequest(url: url))
        }
    }

    private static func dialogTitle(for frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? "This page says" : "\(host) says"
    }
}
