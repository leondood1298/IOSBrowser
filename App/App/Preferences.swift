import BrowserCore
import Combine
import UIKit

/// The app's appearance setting.
/// How the image and PDF viewers change pages.
nonisolated enum ViewerTransition: String, CaseIterable, Identifiable, Sendable {
    /// The next page simply appears.
    case instant
    case slide

    var id: String { rawValue }

    var name: String {
        switch self {
        case .instant: return "Instant"
        case .slide: return "Slide"
        }
    }
}

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

/// When Face ID (or the passcode) is required.
nonisolated enum AppLockMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case wholeApp
    case privateTabs

    var id: String { rawValue }

    var name: String {
        switch self {
        case .off: return "Off"
        case .wholeApp: return "Whole App"
        case .privateTabs: return "Private Tabs Only"
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
            Key.trackingProtection: true,
            Key.blockedCategories: [TrackerCategory.advertising, .analytics, .social].map(\.rawValue),
            Key.blockWebFonts: false,
            Key.blockJavaScript: false,
            Key.blockPopups: true,
            Key.upgradeToHTTPS: true,
            Key.fraudWarnings: true,
            Key.appLock: AppLockMode.off.rawValue,
            Key.searchSuggestions: false,
            Key.autocompleteTopSites: true,
            Key.autocompleteCustomSites: true,
            Key.confirmDownloads: true,
            Key.downloadFolder: "Downloads",
            Key.sortDownloadsByType: false,
            Key.downloadLiveActivity: true,
            Key.backgroundDownloads: true,
            Key.downloadParts: 4,
            Key.downloadNotifications: true,
            Key.useTrash: true,
            Key.slideshowInterval: 3.0,
            Key.backgroundPlayback: true,
        ])
        if defaults.object(forKey: Key.installDate) == nil {
            defaults.set(Date(), forKey: Key.installDate)
        }
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
        static let trackingProtection = "trackingProtection"
        static let blockedCategories = "blockedTrackerCategories"
        static let blockWebFonts = "blockWebFonts"
        static let blockJavaScript = "blockJavaScript"
        static let blockPopups = "blockPopups"
        static let upgradeToHTTPS = "upgradeToHTTPS"
        static let fraudWarnings = "fraudWarnings"
        static let appLock = "appLock"
        static let lifetimeTrackers = "lifetimeTrackersBlocked"
        static let installDate = "installDate"
        static let searchSuggestions = "searchSuggestions"
        static let searchSuggestionsPrompted = "searchSuggestionsPrompted"
        static let autocompleteTopSites = "autocompleteTopSites"
        static let autocompleteCustomSites = "autocompleteCustomSites"
        static let customDomains = "customAutocompleteDomains"
        static let confirmDownloads = "confirmDownloads"
        static let downloadFolder = "downloadFolder"
        static let sortDownloadsByType = "sortDownloadsByType"
        static let downloadLiveActivity = "downloadLiveActivity"
        static let backgroundDownloads = "backgroundDownloads"
        static let downloadParts = "downloadParts"
        static let downloadNotifications = "downloadNotifications"
        static let useTrash = "useTrash"
        static let viewerTransition = "viewerTransition"
        static let slideshowInterval = "slideshowInterval"
        static let pdfPages = "pdfPages"
        static let backgroundPlayback = "backgroundPlayback"
    }

    // MARK: Privacy

    /// Firefox Focus's "Enhanced Tracking Protection" master switch.
    var trackingProtectionEnabled: Bool {
        get { defaults.bool(forKey: Key.trackingProtection) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.trackingProtection) }
    }

    func isBlocking(_ category: TrackerCategory) -> Bool {
        (defaults.stringArray(forKey: Key.blockedCategories) ?? []).contains(category.rawValue)
    }

    func setBlocking(_ category: TrackerCategory, _ blocked: Bool) {
        objectWillChange.send()
        var categories = Set(defaults.stringArray(forKey: Key.blockedCategories) ?? [])
        if blocked {
            categories.insert(category.rawValue)
        } else {
            categories.remove(category.rawValue)
        }
        defaults.set(categories.sorted(), forKey: Key.blockedCategories)
    }

    var blockWebFonts: Bool {
        get { defaults.bool(forKey: Key.blockWebFonts) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.blockWebFonts) }
    }

    var blockJavaScript: Bool {
        get { defaults.bool(forKey: Key.blockJavaScript) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.blockJavaScript) }
    }

    var blockPopups: Bool {
        get { defaults.bool(forKey: Key.blockPopups) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.blockPopups) }
    }

    var upgradeToHTTPS: Bool {
        get { defaults.bool(forKey: Key.upgradeToHTTPS) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.upgradeToHTTPS) }
    }

    var fraudWarnings: Bool {
        get { defaults.bool(forKey: Key.fraudWarnings) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.fraudWarnings) }
    }

    var appLock: AppLockMode {
        get { AppLockMode(rawValue: defaults.string(forKey: Key.appLock) ?? "") ?? .off }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.appLock) }
    }

    /// Trackers blocked since the app was installed (survives Erase, like Focus's counter).
    var lifetimeTrackersBlocked: Int {
        defaults.integer(forKey: Key.lifetimeTrackers)
    }

    func addBlockedTrackers(_ count: Int) {
        guard count > 0 else { return }
        defaults.set(defaults.integer(forKey: Key.lifetimeTrackers) + count, forKey: Key.lifetimeTrackers)
    }

    var installDate: Date {
        defaults.object(forKey: Key.installDate) as? Date ?? Date()
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

    /// The chosen search engine; SearchEngineStore resolves it.
    var searchEngineID: String {
        get { defaults.string(forKey: Key.searchEngineID) ?? SearchEngine.google.id }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.searchEngineID) }
    }

    /// Opt-in, as in Firefox Focus: what you type is sent to the search engine.
    var searchSuggestionsEnabled: Bool {
        get { defaults.bool(forKey: Key.searchSuggestions) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.searchSuggestions) }
    }

    /// Whether the "Show search suggestions?" prompt has been answered.
    var searchSuggestionsPrompted: Bool {
        get { defaults.bool(forKey: Key.searchSuggestionsPrompted) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.searchSuggestionsPrompted) }
    }

    var autocompleteTopSites: Bool {
        get { defaults.bool(forKey: Key.autocompleteTopSites) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.autocompleteTopSites) }
    }

    var autocompleteCustomSites: Bool {
        get { defaults.bool(forKey: Key.autocompleteCustomSites) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.autocompleteCustomSites) }
    }

    /// The user's own sites for URL autocomplete ("My Sites").
    var customAutocompleteDomains: [String] {
        get { defaults.stringArray(forKey: Key.customDomains) ?? [] }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.customDomains) }
    }

    // MARK: Downloads

    /// Show the name, size and folder before a download starts.
    var confirmDownloads: Bool {
        get { defaults.bool(forKey: Key.confirmDownloads) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.confirmDownloads) }
    }

    /// The folder under Documents that downloads go to.
    var downloadFolder: String {
        get { defaults.string(forKey: Key.downloadFolder) ?? "Downloads" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.downloadFolder) }
    }

    /// Put videos in Videos, music in Music, images in Pictures and documents in Documents.
    var sortDownloadsByType: Bool {
        get { defaults.bool(forKey: Key.sortDownloadsByType) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.sortDownloadsByType) }
    }

    /// Show running downloads in a Live Activity, which also keeps them going in the background.
    var downloadLiveActivity: Bool {
        get { defaults.bool(forKey: Key.downloadLiveActivity) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.downloadLiveActivity) }
    }

    /// Hand normal downloads that can be resumed to the system, so they continue while the app
    /// is closed.
    var backgroundDownloads: Bool {
        get { defaults.bool(forKey: Key.backgroundDownloads) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.backgroundDownloads) }
    }

    /// A notification when a download finishes or fails while the app isn't in front.
    var downloadNotifications: Bool {
        get { defaults.bool(forKey: Key.downloadNotifications) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.downloadNotifications) }
    }

    // MARK: Viewers

    var viewerTransition: ViewerTransition {
        get { ViewerTransition(rawValue: defaults.string(forKey: Key.viewerTransition) ?? "") ?? .instant }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.viewerTransition) }
    }

    /// Seconds each image shows in a slideshow.
    var slideshowInterval: Double {
        get { defaults.double(forKey: Key.slideshowInterval) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.slideshowInterval) }
    }

    /// The page each PDF was left on, by its path under Documents.
    var pdfPages: [String: Int] {
        defaults.dictionary(forKey: Key.pdfPages) as? [String: Int] ?? [:]
    }

    func setPDFPage(_ page: Int, for path: String) {
        var pages = pdfPages
        pages[path] = page
        defaults.set(pages, forKey: Key.pdfPages)
    }

    /// Videos keep playing (as sound) when the app goes to the background.
    var backgroundPlayback: Bool {
        get { defaults.bool(forKey: Key.backgroundPlayback) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.backgroundPlayback) }
    }

    /// Deleted files go to the Trash for 30 days instead of being deleted right away.
    var useTrash: Bool {
        get { defaults.bool(forKey: Key.useTrash) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.useTrash) }
    }

    /// How many parts a background download is fetched in at once (1 turns it off).
    var downloadParts: Int {
        get { min(max(defaults.integer(forKey: Key.downloadParts), 1), 8) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.downloadParts) }
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
