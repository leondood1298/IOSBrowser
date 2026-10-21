import Foundation

/// App-wide state shared by every window.
final class AppServices {
    static let shared = AppServices()

    let preferences: Preferences
    let privateSession: PrivateSession
    let tabStore: TabStore
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let siteSettings: SiteSettingsStore
    let favicons: FaviconStore

    init(
        preferences: Preferences = Preferences(),
        privateSession: PrivateSession = PrivateSession(),
        tabStore: TabStore = TabStore(),
        history: HistoryStore = HistoryStore(),
        bookmarks: BookmarkStore = BookmarkStore(),
        siteSettings: SiteSettingsStore = SiteSettingsStore(),
        favicons: FaviconStore = FaviconStore()
    ) {
        self.preferences = preferences
        self.privateSession = privateSession
        self.tabStore = tabStore
        self.history = history
        self.bookmarks = bookmarks
        self.siteSettings = siteSettings
        self.favicons = favicons
    }
}
