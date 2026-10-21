import Foundation

/// Firefox Focus's tracker categories.
public enum TrackerCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case advertising
    case analytics
    case social
    case content

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .advertising: return "Advertising"
        case .analytics: return "Analytics"
        case .social: return "Social"
        case .content: return "Content"
        }
    }

    /// The bundled block list for this category.
    public var listName: String { "disconnect-block-\(rawValue)" }
}

/// Counts of trackers seen on a page, by category.
public struct TrackerCounts: Equatable, Sendable {
    public private(set) var byCategory: [TrackerCategory: Int] = [:]

    public init() {}

    public var total: Int { byCategory.values.reduce(0, +) }

    public subscript(category: TrackerCategory) -> Int {
        byCategory[category] ?? 0
    }

    public mutating func add(_ category: TrackerCategory) {
        byCategory[category, default: 0] += 1
    }
}

/// Decides which tracker category (if any) a request belongs to, using the same block lists the
/// content blocker compiles. Like Firefox Focus's TPStatsBlocklistChecker, it lets the browser
/// count blocked trackers, which WebKit doesn't report.
public struct TrackerMatcher: Sendable {
    private struct Rule: Sendable {
        let category: TrackerCategory
        let unlessDomains: [String]
    }

    private let rulesByDomain: [String: [Rule]]
    private let suffixes: PublicSuffixList

    /// `lists` maps each category to its WebKit rule-list JSON.
    public init(lists: [TrackerCategory: Data], publicSuffixList: PublicSuffixList) {
        var index: [String: [Rule]] = [:]
        for category in TrackerCategory.allCases {
            guard let data = lists[category],
                  let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            for rule in rules {
                guard let trigger = rule["trigger"] as? [String: Any],
                      let filter = trigger["url-filter"] as? String,
                      let domain = Self.domain(fromFilter: filter)
                else { continue }
                let unless = (trigger["unless-domain"] as? [String] ?? []).map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
                index[domain, default: []].append(Rule(category: category, unlessDomains: unless))
            }
        }
        rulesByDomain = index
        suffixes = publicSuffixList
    }

    /// The tracker domain in a filter like `^https?://([^/]+\.)?example\.com`.
    static func domain(fromFilter filter: String) -> String? {
        let prefix = "^https?://([^/]+\\.)?"
        guard filter.hasPrefix(prefix) else { return nil }
        let domain = filter.dropFirst(prefix.count).replacingOccurrences(of: "\\.", with: ".")
        return domain.isEmpty ? nil : domain.lowercased()
    }

    /// The category of `resource` when loaded by `page`, or nil if it isn't a blocked tracker.
    /// Rules apply to third-party requests only, and not on the tracker owner's own sites.
    public func category(for resource: URL, on page: URL?) -> TrackerCategory? {
        guard let host = resource.host?.lowercased(), !host.isEmpty else { return nil }
        let pageHost = page?.host?.lowercased() ?? ""
        if !pageHost.isEmpty, registrable(host) == registrable(pageHost) {
            return nil
        }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count >= 2 {
            let candidate = labels.joined(separator: ".")
            if let rules = rulesByDomain[candidate] {
                for rule in rules where !rule.unlessDomains.contains(where: { Self.host(pageHost, isWithin: $0) }) {
                    return rule.category
                }
            }
            labels.removeFirst()
        }
        return nil
    }

    private func registrable(_ host: String) -> String {
        suffixes.registrableDomain(for: host) ?? host
    }

    static func host(_ host: String, isWithin domain: String) -> Bool {
        !host.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }
}

/// Per-site exceptions for the content blocker, following Firefox's safelist: a rule appended to
/// each list that tells WebKit to ignore every earlier rule on those sites.
public enum SafelistRules {
    /// `ruleList` with an `ignore-previous-rules` rule for `domains` (and their subdomains) appended.
    public static func appending(exceptions domains: [String], to ruleList: String) -> String {
        let cleaned = domains.map { $0.lowercased() }.filter { !$0.isEmpty }.sorted()
        guard !cleaned.isEmpty,
              let end = ruleList.lastIndex(of: "]"),
              let data = try? JSONSerialization.data(withJSONObject: cleaned.map { "*" + $0 }),
              let domainsJSON = String(data: data, encoding: .utf8)
        else { return ruleList }
        let body = ruleList[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = body.hasSuffix("[") ? "\n" : ",\n"
        let rule = "{\"action\":{\"type\":\"ignore-previous-rules\"},\"trigger\":{\"url-filter\":\".*\",\"if-domain\":\(domainsJSON)}}"
        return body + separator + rule + "\n]"
    }
}
