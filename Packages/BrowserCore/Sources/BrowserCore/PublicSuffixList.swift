import Foundation

/// Finds a host's registrable domain ("eTLD+1") with the Public Suffix List, so `news.bbc.co.uk`
/// and `www.bbc.co.uk` count as the same site. Used to decide whether a request is third-party.
public struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    /// Parses the list's text format (one rule per line, `//` comments, `*.` wildcards, `!` exceptions).
    public init(text: String) {
        var rules = Set<String>()
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            if line.hasPrefix("!") {
                exceptions.insert(String(line.dropFirst()))
            } else if line.hasPrefix("*.") {
                wildcards.insert(String(line.dropFirst(2)))
            } else {
                rules.insert(line)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    /// The registrable domain of `host`, or nil when the host is itself a public suffix
    /// (or an IP address).
    public func registrableDomain(for host: String) -> String? {
        var name = host.lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty, !Self.isIPAddress(name) else { return nil }
        let labels = name.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }

        var suffixLength = 1  // the implicit "*" rule: the last label is a public suffix
        for index in 0..<labels.count {
            let candidate = labels[index...].joined(separator: ".")
            if exceptions.contains(candidate) {
                suffixLength = labels.count - index - 1
                break
            }
            let parent = labels[(index + 1)...].joined(separator: ".")
            if rules.contains(candidate) || (index + 1 < labels.count && wildcards.contains(parent)) {
                suffixLength = labels.count - index
                break
            }
        }
        guard labels.count > suffixLength else { return nil }
        return labels.suffix(suffixLength + 1).joined(separator: ".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }
}
