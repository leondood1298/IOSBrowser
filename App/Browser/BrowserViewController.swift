import BrowserCore
import Combine
import UIKit
import WebKit

/// Single-tab browser used to prove the build → sign → install pipeline (M0).
/// M1 replaces it with the tabbed browser shell.
final class BrowserViewController: UIViewController {
    private let webView: WKWebView
    private let urlField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let searchEngine = SearchEngine.google
    private var cancellables: Set<AnyCancellable> = []

    private lazy var backButton = UIBarButtonItem(
        image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(goBack))
    private lazy var forwardButton = UIBarButtonItem(
        image: UIImage(systemName: "chevron.forward"), style: .plain, target: self, action: #selector(goForward))
    private lazy var reloadButton = UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(reloadOrStop))

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.ignoresViewportScaleLimits = true
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureWebView()
        configureProgressView()
        configureNavigationBar()
        observeWebView()
        showStartPage()
    }

    /// Handles `iosbrowser://open-url?url=…` and `iosbrowser://open-text?text=…`.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "iosbrowser" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host?.lowercased() {
        case "open-url":
            if let target = items.first(where: { $0.name == "url" })?.value {
                load(input: target)
            }
        case "open-text":
            if let text = items.first(where: { $0.name == "text" })?.value {
                load(input: text)
            }
        default:
            break
        }
    }

    // MARK: - Setup

    private func configureWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.accessibilityIdentifier = "webView"
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureProgressView() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureNavigationBar() {
        navigationItem.style = .browser

        urlField.borderStyle = .roundedRect
        urlField.placeholder = "Search or enter address"
        urlField.keyboardType = .webSearch
        urlField.returnKeyType = .go
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.spellCheckingType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.textContentType = .URL
        urlField.accessibilityIdentifier = "urlField"
        urlField.delegate = self

        let preferredWidth = urlField.widthAnchor.constraint(equalToConstant: 640)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        navigationItem.titleView = urlField
        navigationItem.leftBarButtonItems = [backButton, forwardButton]
        navigationItem.rightBarButtonItems = [reloadButton]
        updateNavigationButtons()
    }

    private func observeWebView() {
        webView.publisher(for: \.estimatedProgress)
            .sink { [weak self] progress in self?.updateProgress(progress) }
            .store(in: &cancellables)
        webView.publisher(for: \.url)
            .sink { [weak self] _ in self?.updateURLField() }
            .store(in: &cancellables)
        webView.publisher(for: \.isLoading)
            .sink { [weak self] _ in self?.updateNavigationButtons() }
            .store(in: &cancellables)
        webView.publisher(for: \.canGoBack)
            .sink { [weak self] _ in self?.updateNavigationButtons() }
            .store(in: &cancellables)
        webView.publisher(for: \.canGoForward)
            .sink { [weak self] _ in self?.updateNavigationButtons() }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    private func load(input: String) {
        switch URIFixup.classify(input) {
        case .url(let url)?:
            load(url)
        case .search(let query)?:
            if let url = searchEngine.searchURL(for: query) {
                load(url)
            }
        case nil:
            break
        }
    }

    private func load(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if URIFixup.webSchemes.contains(scheme) {
            webView.load(URLRequest(url: url))
        } else {
            // mailto:, tel: and other app links. M1a adds a confirmation prompt.
            UIApplication.shared.open(url)
        }
    }

    private func showStartPage() {
        webView.loadHTMLString(Self.startPageHTML, baseURL: nil)
    }

    // MARK: - UI state

    private func updateProgress(_ progress: Double) {
        progressView.setProgress(Float(progress), animated: progress > 0.05)
        progressView.isHidden = progress >= 1 || !webView.isLoading
    }

    private func updateURLField() {
        guard !urlField.isFirstResponder else { return }
        urlField.text = displayString(for: webView.url)
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        reloadButton.image = UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise")
        progressView.isHidden = !webView.isLoading
    }

    private func displayString(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url.absoluteString
    }

    // MARK: - Actions

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url == nil || displayString(for: webView.url) == nil {
            showStartPage()
        } else {
            webView.reload()
        }
    }

    private func showError(_ error: Error, failingURL: URL?) {
        let nsError = error as NSError
        // Cancelled loads and "frame load interrupted" (downloads, app links) are not failures.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        let message = nsError.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let html = Self.errorPageHTML.replacingOccurrences(of: "{message}", with: message)
        webView.loadHTMLString(html, baseURL: failingURL)
    }

    private static let startPageHTML = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,system-ui;display:flex;align-items:center;justify-content:center;
        height:90vh;margin:0;color:#8e8e93}h1{font-weight:500;font-size:28px}</style></head>
        <body><h1>Search or enter an address above</h1></body></html>
        """

    private static let errorPageHTML = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,system-ui;margin:15vh 10vw;color:#3a3a3c}
        @media (prefers-color-scheme: dark){body{background:#000;color:#e5e5ea}}
        h1{font-weight:600;font-size:26px}button{font-size:17px;padding:10px 22px;border-radius:10px;border:0;
        background:#0a84ff;color:#fff}</style></head>
        <body><h1>This page couldn't be loaded</h1><p>{message}</p>
        <button onclick="location.reload()">Try again</button></body></html>
        """
}

// MARK: - UITextFieldDelegate

extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text = displayString(for: webView.url)
        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        load(input: textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        updateURLField()
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return .allow
        }
        if URIFixup.webSchemes.contains(scheme) {
            return .allow
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, failingURL: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, failingURL: webView.url)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Single tab for now: open target=_blank links in place. M1a opens them as new tabs.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
