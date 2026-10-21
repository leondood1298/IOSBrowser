import Foundation

/// One page in history (the latest visit to that URL).
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public var visitCount: Int

    public var id: URL { url }

    public init(url: URL, title: String, lastVisit: Date, visitCount: Int = 1) {
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visitCount = visitCount
    }
}

/// The pages visited on one day.
public struct HistoryDay: Equatable, Sendable, Identifiable {
    public var day: Date
    public var entries: [HistoryEntry]

    public var id: Date { day }
}

/// Browsing history for normal tabs, one entry per URL, capped by count and age.
public struct HistoryIndex: Codable, Equatable, Sendable {
    public private(set) var entries: [URL: HistoryEntry]
    public var maximumEntries: Int
    public var maximumAge: TimeInterval

    public init(entries: [HistoryEntry] = [], maximumEntries: Int = 10_000, maximumAge: TimeInterval = 180 * 86_400) {
        self.entries = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { $0.lastVisit > $1.lastVisit ? $0 : $1 })
        self.maximumEntries = maximumEntries
        self.maximumAge = maximumAge
    }

    /// Records a visit. Only http(s) pages are kept.
    public mutating func recordVisit(to url: URL, title: String, at date: Date = Date()) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        var entry = entries[url] ?? HistoryEntry(url: url, title: title, lastVisit: date, visitCount: 0)
        entry.visitCount += 1
        entry.lastVisit = date
        if !title.isEmpty {
            entry.title = title
        }
        entries[url] = entry
        trim(now: date)
    }

    /// Updates the title of a recorded page (titles often arrive after the visit).
    public mutating func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, entries[url] != nil else { return }
        entries[url]?.title = title
    }

    public mutating func remove(_ url: URL) {
        entries[url] = nil
    }

    /// Removes visits made at or after `date` (nil removes everything).
    public mutating func removeVisits(since date: Date?) {
        guard let date else {
            entries.removeAll()
            return
        }
        entries = entries.filter { $0.value.lastVisit < date }
    }

    /// Newest first, optionally filtered by text in the title or URL.
    public func search(_ text: String = "", limit: Int? = nil) -> [HistoryEntry] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results = entries.values.filter { entry in
            query.isEmpty || entry.title.lowercased().contains(query) || entry.url.absoluteString.lowercased().contains(query)
        }
        results.sort { $0.lastVisit > $1.lastVisit }
        if let limit {
            return Array(results.prefix(limit))
        }
        return results
    }

    /// Entries grouped by calendar day, newest day first.
    public func groupedByDay(_ text: String = "", calendar: Calendar = .current) -> [HistoryDay] {
        let grouped = Dictionary(grouping: search(text)) { calendar.startOfDay(for: $0.lastVisit) }
        return grouped.keys.sorted(by: >).map { day in
            HistoryDay(day: day, entries: grouped[day, default: []].sorted { $0.lastVisit > $1.lastVisit })
        }
    }

    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-maximumAge)
        if entries.values.contains(where: { $0.lastVisit < cutoff }) {
            entries = entries.filter { $0.value.lastVisit >= cutoff }
        }
        if entries.count > maximumEntries {
            let keep = entries.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(maximumEntries)
            entries = Dictionary(keep.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
