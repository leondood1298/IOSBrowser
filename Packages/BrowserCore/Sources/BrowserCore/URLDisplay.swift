import Foundation

/// How URLs appear in the address bar.
public enum URLDisplay {
    /// The host shown while the address bar isn't being edited: no scheme, no "www." and no
    /// user info, so `https://google.com@evil.example` shows as `evil.example`.
    public static func host(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The full address shown while editing, with any user info removed. `nil` for pages that
    /// have no address worth showing, such as `about:blank` or `data:` URLs.
    public static func editableText(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else {
            return ["about", "data", "blob"].contains(scheme) ? nil : url.absoluteString
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        return components.string ?? url.absoluteString
    }

    /// A short title for a tab: the page title, else the host, else "New Tab".
    public static func tabTitle(pageTitle: String?, url: URL?) -> String {
        if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return host(for: url) ?? "New Tab"
    }
}
