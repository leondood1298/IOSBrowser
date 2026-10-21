import Foundation

/// Whether a site gets its desktop or mobile layout.
public enum SiteLayout: String, Codable, Sendable {
    case desktop
    case mobile
}

/// Choices remembered per site (by host, ignoring "www.").
public struct SiteSettings: Codable, Equatable, Sendable {
    /// Page zoom, where 1.0 is 100%.
    public var zoom: Double?
    public var layout: SiteLayout?
    public var userAgent: UserAgent?
    public var customUserAgent: String?
    /// Tracking protection switched off for this site (M2).
    public var trackingProtectionDisabled: Bool?

    public init(
        zoom: Double? = nil, layout: SiteLayout? = nil, userAgent: UserAgent? = nil,
        customUserAgent: String? = nil, trackingProtectionDisabled: Bool? = nil
    ) {
        self.zoom = zoom
        self.layout = layout
        self.userAgent = userAgent
        self.customUserAgent = customUserAgent
        self.trackingProtectionDisabled = trackingProtectionDisabled
    }

    public var isEmpty: Bool {
        zoom == nil && layout == nil && userAgent == nil && customUserAgent == nil && trackingProtectionDisabled == nil
    }
}

/// All per-site settings, keyed by site.
public struct SiteSettingsIndex: Codable, Equatable, Sendable {
    public private(set) var sites: [String: SiteSettings]

    public init(sites: [String: SiteSettings] = [:]) {
        self.sites = sites
    }

    /// The key for a URL: its lowercased host without a leading "www.".
    public static func key(for url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func settings(for url: URL?) -> SiteSettings {
        Self.key(for: url).flatMap { sites[$0] } ?? SiteSettings()
    }

    public mutating func update(_ url: URL?, _ change: (inout SiteSettings) -> Void) {
        guard let key = Self.key(for: url) else { return }
        var settings = sites[key] ?? SiteSettings()
        change(&settings)
        sites[key] = settings.isEmpty ? nil : settings
    }
}

/// The zoom steps Safari offers.
public enum ZoomLevels {
    public static let steps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    public static func next(after zoom: Double) -> Double {
        steps.first { $0 > zoom + 0.001 } ?? steps[steps.count - 1]
    }

    public static func previous(before zoom: Double) -> Double {
        steps.last { $0 < zoom - 0.001 } ?? steps[0]
    }

    public static func percentText(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}
