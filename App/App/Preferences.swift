import BrowserCore
import Combine
import Foundation

/// User settings stored in UserDefaults. Changes publish through `objectWillChange`.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.askBeforeOpeningApps: true,
            Key.allowLinksToOpenApps: false,
            Key.searchEngineID: SearchEngine.google.id,
        ])
    }

    private enum Key {
        static let askBeforeOpeningApps = "askBeforeOpeningApps"
        static let allowLinksToOpenApps = "allowLinksToOpenApps"
        static let searchEngineID = "searchEngineID"
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
}
