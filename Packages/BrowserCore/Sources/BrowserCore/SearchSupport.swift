import Foundation

extension SearchEngine {
    /// The search terms in `url` when it's this engine's results page, so the address bar can show
    /// what was searched instead of the results URL (Firefox Focus does the same).
    public func searchTerms(in url: URL) -> String? {
        let marker = "SEARCHTERMSMARKER"
        let placeholder = searchTemplate.contains("{searchTerms}") ? "{searchTerms}" : "%s"
        guard let template = URLComponents(string: searchTemplate.replacingOccurrences(of: placeholder, with: marker)),
              let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
              template.host?.lowercased() == page.host?.lowercased(),
              template.path == page.path,
              let name = template.queryItems?.first(where: { $0.value == marker })?.name,
              let raw = page.percentEncodedQueryItems?.first(where: { $0.name == name })?.value
        else { return nil }
        let terms = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        return terms.isEmpty ? nil : terms
    }

    /// Checks a custom engine's template: it must contain `%s` and make an http(s) URL.
    public static func isValidTemplate(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%s"),
              let url = URL(string: trimmed.replacingOccurrences(of: "%s", with: "test")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}

/// Parses search suggestion responses in the OpenSearch JSON format: `["query", ["one", "two"], …]`.
public enum SuggestParser {
    public static func parse(_ data: Data, limit: Int = 5) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count >= 2,
              let list = json[1] as? [Any]
        else { return [] }
        return Array(list.compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(limit))
    }
}

/// Inline URL autocomplete, following Firefox Focus: typing the start of a site's name completes
/// it from a built-in list of popular sites and the user's own list.
public struct DomainCompletion: Sendable {
    public var topDomains: [String]
    public var customDomains: [String]
    public var usesTopDomains: Bool
    public var usesCustomDomains: Bool

    public init(topDomains: [String], customDomains: [String], usesTopDomains: Bool = true, usesCustomDomains: Bool = true) {
        self.topDomains = topDomains
        self.customDomains = customDomains
        self.usesTopDomains = usesTopDomains
        self.usesCustomDomains = usesCustomDomains
    }

    /// The text to add after `typed`, e.g. "gle.com" for "goo", or nil when nothing matches.
    /// Matches start at a label boundary ("www.goo" and "goo" both complete google.com) but never
    /// inside the top-level domain alone.
    public func completion(for typed: String) -> String? {
        let text = typed.lowercased()
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else { return nil }
        let sources = (usesCustomDomains ? customDomains : []) + (usesTopDomains ? topDomains : [])
        for domain in sources {
            let full = domain.hasPrefix("www.") ? domain.lowercased() : "www." + domain.lowercased()
            for candidate in Self.labelSuffixes(of: full) where candidate.hasPrefix(text) && candidate.count > text.count {
                return String(candidate.dropFirst(text.count))
            }
        }
        return nil
    }

    /// "www.google.com" → ["www.google.com", "google.com"] (stops before the top-level domain).
    static func labelSuffixes(of domain: String) -> [String] {
        let labels = domain.split(separator: ".")
        guard labels.count >= 2 else { return [domain] }
        return (0..<(labels.count - 1)).map { labels[$0...].joined(separator: ".") }
    }

    /// Cleans a user-entered site for the custom list: no scheme, "www." or trailing slash.
    /// Returns nil unless it looks like a domain (contains a dot).
    public static func normalizedDomain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") {
            text.removeFirst(4)
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard text.contains("."), !text.contains(where: \.isWhitespace), !text.hasPrefix("."), !text.hasSuffix(".") else {
            return nil
        }
        return text
    }
}
