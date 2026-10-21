import BrowserCore
import UIKit
import WebKit

/// Share, print and save the current page, or hand it to another browser.
enum PageActions {
    /// Shows the share sheet. Passing the web view lets iOS offer "Add to Home Screen".
    static func share(_ tab: TabModel, from presenter: UIViewController, source: UIBarButtonItem?) {
        guard let url = tab.url else { return }
        var items: [Any] = [url]
        if let webView = tab.webView {
            items.append(webView)
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceItem = source
        presenter.present(controller, animated: true)
    }

    static func share(items: [Any], from presenter: UIViewController, sourceView: UIView) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = sourceView
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        presenter.present(controller, animated: true)
    }

    static func print(_ tab: TabModel) {
        guard let webView = tab.webView else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = tab.title
        info.outputType = .general
        let printer = UIPrintInteractionController.shared
        printer.printInfo = info
        printer.printFormatter = webView.viewPrintFormatter()
        _ = printer.present(animated: true)
    }

    /// Saves the whole page as a PDF in Downloads.
    static func savePDF(_ tab: TabModel) async throws -> URL {
        guard let webView = tab.webView else { throw CocoaError(.fileNoSuchFile) }
        let data = try await webView.pdf(configuration: WKPDFConfiguration())
        return try save(data, name: FileNaming.pageFileName(title: tab.pageTitle, url: tab.url, extension: "pdf"))
    }

    /// Saves the page with its images and styles as a .webarchive in Downloads.
    static func saveWebArchive(_ tab: TabModel) async throws -> URL {
        guard let webView = tab.webView else { throw CocoaError(.fileNoSuchFile) }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in
                continuation.resume(with: result)
            }
        }
        return try save(data, name: FileNaming.pageFileName(title: tab.pageTitle, url: tab.url, extension: "webarchive"))
    }

    private static func save(_ data: Data, name: String) throws -> URL {
        let folder = AppFolders.documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = FileNaming.uniqueURL(in: folder, for: name)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Other browsers the page can be opened in. Chrome and Firefox appear only when installed.
    static func otherBrowsers(for url: URL) -> [(name: String, url: URL)] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        var browsers: [(String, URL)] = [("Default Browser", url)]
        var chrome = URLComponents(url: url, resolvingAgainstBaseURL: false)
        chrome?.scheme = scheme == "https" ? "googlechromes" : "googlechrome"
        if let chromeURL = chrome?.url, UIApplication.shared.canOpenURL(chromeURL) {
            browsers.append(("Chrome", chromeURL))
        }
        var firefox = URLComponents(string: "firefox://open-url")
        firefox?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let firefoxURL = firefox?.url, UIApplication.shared.canOpenURL(firefoxURL) {
            browsers.append(("Firefox", firefoxURL))
        }
        return browsers
    }
}
