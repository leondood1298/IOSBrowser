import Foundation

/// What the user typed into the address bar: something to load, or a search query.
public enum BrowserInput: Equatable, Sendable {
    case url(URL)
    case search(String)
}

/// Turns address-bar text into a URL when it looks like one and otherwise leaves it as a search.
/// Follows the behaviour of Firefox Focus's URIFixup (typed `javascript:` and `file:` are never
/// loaded) and adds support for ports, IP addresses and localhost.
public enum URIFixup {
    /// Schemes the browser loads in a web view.
    public static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

    /// Schemes that are handed to another app when typed.
    public static let appSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss", "iosbrowser",
    ]

    /// Schemes that are never loaded from typed input.
    public static let blockedSchemes: Set<String> = ["javascript", "file", "vbscript"]

    public static func classify(_ text: String) -> BrowserInput? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = url(from: input) {
            return .url(url)
        }
        return .search(input)
    }

    /// The URL to load for `text`, or `nil` when the text should be searched instead.
    public static func url(from text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let scheme = explicitScheme(in: input) {
            if blockedSchemes.contains(scheme) {
                return nil
            }
            if scheme == "http" || scheme == "https" {
                let encoded = input.replacingOccurrences(of: " ", with: "%20")
                guard let url = URL(string: encoded), let host = url.host, !host.isEmpty else { return nil }
                return url
            }
            if webSchemes.contains(scheme) || appSchemes.contains(scheme) {
                return URL(string: input)
            }
            if input.contains("://") && !input.contains(where: \.isWhitespace) {
                return URL(string: input)
            }
            return nil
        }

        // Plain host (with optional port and path). Anything with spaces or an "@" is a search.
        guard !input.contains(where: \.isWhitespace), !input.contains("@") else { return nil }
        let authority = String(input.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard let (host, port) = splitHostAndPort(authority), isPlausibleHost(host) else { return nil }
        if let port, !(1...65535).contains(port) {
            return nil
        }
        let scheme = (host == "localhost" || isIPAddress(host)) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(input)"), let parsedHost = url.host, !parsedHost.isEmpty else {
            return nil
        }
        return url
    }

    /// The lowercased scheme when the text starts with one. Returns `nil` for plain hosts such as
    /// `localhost:8080` or `example.com:443/path`, where the "scheme" is really a host and port.
    static func explicitScheme(in input: String) -> String? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let candidate = input[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }

        let rest = input[input.index(after: colon)...]
        let portDigits = rest.prefix { $0.isASCII && $0.isNumber }
        let afterPort = rest.dropFirst(portDigits.count)
        let looksLikePort = !portDigits.isEmpty && (afterPort.first.map { "/?#".contains($0) } ?? true)
        let lowered = candidate.lowercased()
        if looksLikePort && (lowered == "localhost" || lowered.contains(".")) {
            return nil
        }
        return lowered
    }

    static func splitHostAndPort(_ authority: String) -> (host: String, port: Int?)? {
        guard !authority.isEmpty else { return nil }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = authority[...close].lowercased()
            let remainder = authority[authority.index(after: close)...]
            if remainder.isEmpty {
                return (host, nil)
            }
            guard remainder.first == ":", let port = Int(remainder.dropFirst()) else { return nil }
            return (host, port)
        }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return (authority.lowercased(), nil)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return (parts[0].lowercased(), port)
        default:
            return nil
        }
    }

    static func isPlausibleHost(_ host: String) -> Bool {
        if host == "localhost" || isIPAddress(host) {
            return true
        }
        var name = host
        if name.hasSuffix(".") {
            name.removeLast()
        }
        guard !name.isEmpty, name.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { return false }
        }
        guard let topLevel = labels.last else { return false }
        if topLevel.lowercased().hasPrefix("xn--") {
            return true
        }
        return topLevel.count >= 2 && topLevel.allSatisfy(\.isLetter)
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return host.count > 2
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(octet)
            else { return false }
            return value <= 255
        }
    }
}
