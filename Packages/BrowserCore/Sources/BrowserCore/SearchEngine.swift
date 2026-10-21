import Foundation

/// A web search provider described by URL templates in which `%s` (or `{searchTerms}`)
/// stands for the query.
public struct SearchEngine: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var searchTemplate: String
    public var suggestTemplate: String?

    public init(id: String, name: String, searchTemplate: String, suggestTemplate: String? = nil) {
        self.id = id
        self.name = name
        self.searchTemplate = searchTemplate
        self.suggestTemplate = suggestTemplate
    }

    public func searchURL(for query: String) -> URL? {
        Self.fill(searchTemplate, with: query)
    }

    public func suggestURL(for query: String) -> URL? {
        suggestTemplate.flatMap { Self.fill($0, with: query) }
    }

    /// RFC 3986 unreserved characters; everything else in the query is percent-encoded.
    static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func fill(_ template: String, with query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: queryAllowed)
        else { return nil }
        let placeholder = template.contains("{searchTerms}") ? "{searchTerms}" : "%s"
        guard template.contains(placeholder) else { return nil }
        return URL(string: template.replacingOccurrences(of: placeholder, with: encoded))
    }
}

extension SearchEngine {
    public static let google = SearchEngine(
        id: "google", name: "Google",
        searchTemplate: "https://www.google.com/search?q=%s&ie=utf-8&oe=utf-8",
        suggestTemplate: "https://www.google.com/complete/search?client=firefox&q=%s")

    public static let duckDuckGo = SearchEngine(
        id: "duckduckgo", name: "DuckDuckGo",
        searchTemplate: "https://duckduckgo.com/?q=%s",
        suggestTemplate: "https://ac.duckduckgo.com/ac/?q=%s&type=list")

    public static let bing = SearchEngine(
        id: "bing", name: "Bing",
        searchTemplate: "https://www.bing.com/search?q=%s",
        suggestTemplate: "https://www.bing.com/osjson.aspx?query=%s")

    public static let wikipedia = SearchEngine(
        id: "wikipedia", name: "Wikipedia",
        searchTemplate: "https://en.wikipedia.org/wiki/Special:Search?search=%s",
        suggestTemplate: "https://en.wikipedia.org/w/api.php?action=opensearch&search=%s")

    public static let amazon = SearchEngine(
        id: "amazon", name: "Amazon.com",
        searchTemplate: "https://www.amazon.com/s?k=%s",
        suggestTemplate: "https://completion.amazon.com/search/complete?search-alias=aps&mkt=1&q=%s")

    public static let brave = SearchEngine(
        id: "brave", name: "Brave Search",
        searchTemplate: "https://search.brave.com/search?q=%s",
        suggestTemplate: "https://search.brave.com/api/suggest?q=%s")

    public static let ecosia = SearchEngine(
        id: "ecosia", name: "Ecosia",
        searchTemplate: "https://www.ecosia.org/search?q=%s",
        suggestTemplate: "https://ac.ecosia.org/autocomplete?q=%s&type=list")

    public static let startpage = SearchEngine(
        id: "startpage", name: "Startpage",
        searchTemplate: "https://www.startpage.com/sp/search?query=%s")

    public static let youtube = SearchEngine(
        id: "youtube", name: "YouTube",
        searchTemplate: "https://www.youtube.com/results?search_query=%s",
        suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=%s")

    /// Firefox Focus's en-US engines first, then the extras.
    public static let builtIn: [SearchEngine] = [
        google, duckDuckGo, amazon, wikipedia, bing, brave, ecosia, startpage, youtube,
    ]
}
