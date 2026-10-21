import Foundation

/// The browser's own links (iosbrowser://…), used by the share extension and other apps:
/// open an address or text in a new tab, or download a file.
public enum AppLink: Hashable, Sendable {
    case open(URL, isPrivate: Bool)
    /// Text to search for or to treat as an address, as typed in the address bar.
    case openText(String, isPrivate: Bool)
    case download(URL)

    public static let scheme = "iosbrowser"

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .open(let address, let isPrivate):
            components.host = "open-url"
            components.queryItems = [URLQueryItem(name: "url", value: address.absoluteString)] + Self.privateItem(isPrivate)
        case .openText(let text, let isPrivate):
            components.host = "open-text"
            components.queryItems = [URLQueryItem(name: "text", value: text)] + Self.privateItem(isPrivate)
        case .download(let address):
            components.host = "download"
            components.queryItems = [URLQueryItem(name: "url", value: address.absoluteString)]
        }
        // "+" means a space in many query parsers; encode it so addresses survive the trip.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let isPrivate = value("private") == "1"
        switch components.host?.lowercased() {
        case "open-url":
            guard let address = value("url").flatMap(URL.init(string:)), address.scheme != nil else { return nil }
            self = .open(address, isPrivate: isPrivate)
        case "open-text":
            guard let text = value("text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .openText(text, isPrivate: isPrivate)
        case "download":
            guard let address = value("url").flatMap(URL.init(string:)),
                  ["http", "https"].contains(address.scheme?.lowercased() ?? "")
            else { return nil }
            self = .download(address)
        default:
            return nil
        }
    }

    private static func privateItem(_ isPrivate: Bool) -> [URLQueryItem] {
        isPrivate ? [URLQueryItem(name: "private", value: "1")] : []
    }
}
