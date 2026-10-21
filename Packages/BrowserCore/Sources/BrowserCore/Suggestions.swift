import Foundation

/// A row in the address bar's suggestion list.
public struct Suggestion: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case openTab(id: UUID)
        case bookmark
        case history
    }

    public var kind: Kind
    public var title: String
    public var url: URL

    public var id: String {
        switch kind {
        case .openTab(let id): return "tab-\(id.uuidString)"
        case .bookmark: return "bookmark-\(url.absoluteString)"
        case .history: return "history-\(url.absoluteString)"
        }
    }

    public init(kind: Kind, title: String, url: URL) {
        self.kind = kind
        self.title = title
        self.url = url
    }
}

/// Ranks open tabs, bookmarks and history against what the user is typing.
public enum SuggestionRanker {
    public struct Candidate: Sendable {
        public var kind: Suggestion.Kind
        public var title: String
        public var url: URL
        public var lastUsed: Date
        public var useCount: Int

        public init(kind: Suggestion.Kind, title: String, url: URL, lastUsed: Date = .distantPast, useCount: Int = 0) {
            self.kind = kind
            self.title = title
            self.url = url
            self.lastUsed = lastUsed
            self.useCount = useCount
        }
    }

    /// The best matches, at most `limit`, with each URL listed once.
    public static func rank(_ input: String, candidates: [Candidate], limit: Int = 8) -> [Suggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        let scored: [(Candidate, Int)] = candidates.compactMap { candidate in
            let score = self.score(candidate, query: query)
            return score > 0 ? (candidate, score) : nil
        }
        let ordered = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.useCount != rhs.0.useCount { return lhs.0.useCount > rhs.0.useCount }
            return lhs.0.lastUsed > rhs.0.lastUsed
        }

        var seen = Set<String>()
        var results: [Suggestion] = []
        for (candidate, _) in ordered {
            let key = BookmarkLibrary.normalized(candidate.url)
            guard seen.insert(key).inserted else { continue }
            results.append(Suggestion(kind: candidate.kind, title: candidate.title, url: candidate.url))
            if results.count == limit { break }
        }
        return results
    }

    static func score(_ candidate: Candidate, query: String) -> Int {
        let host = URLDisplay.host(for: candidate.url) ?? ""
        let address = candidate.url.absoluteString.lowercased()
        let title = candidate.title.lowercased()
        var score = 0
        if host.hasPrefix(query) {
            score = 100
        } else if host.split(separator: ".").contains(where: { $0.hasPrefix(query) }) {
            score = 80
        } else if title.hasPrefix(query) {
            score = 70
        } else if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
            score = 60
        } else if address.contains(query) {
            score = 40
        } else if title.contains(query) {
            score = 30
        }
        guard score > 0 else { return 0 }
        switch candidate.kind {
        case .openTab: score += 15
        case .bookmark: score += 10
        case .history: break
        }
        return score
    }
}
