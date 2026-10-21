import Foundation

/// User agents the browser can present. `.standard` keeps WebKit's own (Safari on iPad).
public enum UserAgent: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard
    case safariMac
    case chromeDesktop
    case firefoxDesktop
    case safariIPhone
    case chromeAndroid
    case custom

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .standard: return "Default (Safari on iPad)"
        case .safariMac: return "Safari on Mac"
        case .chromeDesktop: return "Chrome on Windows"
        case .firefoxDesktop: return "Firefox on Windows"
        case .safariIPhone: return "Safari on iPhone"
        case .chromeAndroid: return "Chrome on Android"
        case .custom: return "Custom"
        }
    }

    /// The string sent to sites, or `nil` to use WebKit's default. `.custom` returns `custom`.
    public func string(custom: String? = nil) -> String? {
        switch self {
        case .standard:
            return nil
        case .safariMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        case .chromeDesktop:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        case .firefoxDesktop:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:144.0) Gecko/20100101 Firefox/144.0"
        case .safariIPhone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        case .chromeAndroid:
            return "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36"
        case .custom:
            let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
