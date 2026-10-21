import Foundation

/// The local page shown when a site can't be loaded.
public enum ErrorPage {
    public struct Content: Equatable, Sendable {
        public var title: String
        public var message: String
    }

    /// Errors that aren't real failures and should not replace the page: cancelled loads,
    /// "frame load interrupted" (downloads and app links) and plug-in handled loads.
    public static func shouldIgnore(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain && code == NSURLErrorCancelled { return true }
        if domain == "WebKitErrorDomain" && (code == 102 || code == 204) { return true }
        return false
    }

    public static func content(domain: String, code: Int, description: String) -> Content {
        guard domain == NSURLErrorDomain else {
            return Content(title: "This page couldn't be loaded", message: description)
        }
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return Content(title: "You're offline", message: "Check your internet connection, then try again.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return Content(title: "Can't find this site", message: "Check the address for typos, then try again.")
        case NSURLErrorTimedOut:
            return Content(title: "This site took too long to respond", message: "Try again in a moment.")
        case NSURLErrorCannotConnectToHost:
            return Content(title: "Can't connect to the server", message: "The site may be down. Try again later.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return Content(
                title: "This connection isn't secure",
                message: "The site's certificate isn't valid, so the browser stopped loading it.")
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return Content(title: "This address isn't valid", message: description)
        default:
            return Content(title: "This page couldn't be loaded", message: description)
        }
    }

    public static func html(_ content: Content, failingURL: URL?) -> String {
        let address = failingURL.map { "<p class=\"url\">\(escape($0.absoluteString))</p>" } ?? ""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(content.title))</title>
            <style>
            :root { color-scheme: light dark; }
            body { font-family: -apple-system, system-ui, sans-serif; margin: 18vh 10vw; color: #3a3a3c; background: #fff; }
            @media (prefers-color-scheme: dark) { body { color: #e5e5ea; background: #1c1c1e; } }
            h1 { font-weight: 600; font-size: 28px; margin-bottom: 8px; }
            p { font-size: 17px; line-height: 1.5; }
            .url { color: #8e8e93; word-break: break-all; font-size: 15px; }
            button { margin-top: 20px; font-size: 17px; padding: 10px 22px; border-radius: 10px; border: 0;
                     background: #0a84ff; color: #fff; }
            </style></head>
            <body><h1>\(escape(content.title))</h1><p>\(escape(content.message))</p>\(address)
            <button onclick="location.reload()">Try again</button></body></html>
            """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
