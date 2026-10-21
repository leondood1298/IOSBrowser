import BrowserCore
import Combine
import UIKit

/// The app's appearance setting.
nonisolated enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// User settings stored in UserDefaults. Changes publish through `objectWillChange`.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.askBeforeOpeningApps: true,
            Key.allowLinksToOpenApps: false,
            Key.searchEngineID: SearchEngine.google.id,
            Key.defaultZoom: 1.0,
            Key.defaultUserAgent: UserAgent.standard.rawValue,
            Key.theme: AppTheme.system.rawValue,
            Key.defaultLayout: SiteLayout.desktop.rawValue,
        ])
    }

    private enum Key {
        static let askBeforeOpeningApps = "askBeforeOpeningApps"
        static let allowLinksToOpenApps = "allowLinksToOpenApps"
        static let searchEngineID = "searchEngineID"
        static let defaultZoom = "defaultZoom"
        static let defaultUserAgent = "defaultUserAgent"
        static let customUserAgent = "customUserAgent"
        static let theme = "theme"
        static let defaultLayout = "defaultLayout"
    }

    var theme: AppTheme {
        get { AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.theme) }
    }

    /// Desktop or mobile layout for sites without their own choice (iPad Safari defaults to desktop).
    var defaultLayout: SiteLayout {
        get { SiteLayout(rawValue: defaults.string(forKey: Key.defaultLayout) ?? "") ?? .desktop }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.defaultLayout) }
    }

    /// Ask before leaving the browser for mail, FaceTime or other apps.
    var askBeforeOpeningApps: Bool {
        get { defaults.bool(forKey: Key.askBeforeOpeningApps) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.askBeforeOpeningApps) }
    }

    /// Let universal links open their app (off keeps you in the browser, like Firefox Focus).
    var allowLinksToOpenApps: Bool {
        get { defaults.bool(forKey: Key.allowLinksToOpenApps) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.allowLinksToOpenApps) }
    }

    var searchEngine: SearchEngine {
        get {
            let id = defaults.string(forKey: Key.searchEngineID)
            return SearchEngine.builtIn.first { $0.id == id } ?? .google
        }
        set { objectWillChange.send(); defaults.set(newValue.id, forKey: Key.searchEngineID) }
    }

    /// Page zoom for sites without their own setting (1.0 = 100%).
    var defaultZoom: Double {
        get { defaults.double(forKey: Key.defaultZoom) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.defaultZoom) }
    }

    /// The user agent for sites without their own setting.
    var defaultUserAgent: UserAgent {
        get { UserAgent(rawValue: defaults.string(forKey: Key.defaultUserAgent) ?? "") ?? .standard }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.defaultUserAgent) }
    }

    /// The string used when the user agent is set to Custom.
    var customUserAgent: String {
        get { defaults.string(forKey: Key.customUserAgent) ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.customUserAgent) }
    }
}
