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
    let searchEngines: SearchEngineStore
    let downloads: DownloadManager
    let files: FileStore
    let audio = AudioPlayback()
    let playlists: PlaylistStore
    let playbackPositions = PlaybackPositions()

    init(
        preferences: Preferences = Preferences(),
        privateSession: PrivateSession = PrivateSession(),
        tabStore: TabStore = TabStore(),
        history: HistoryStore = HistoryStore(),
        bookmarks: BookmarkStore = BookmarkStore(),
        siteSettings: SiteSettingsStore = SiteSettingsStore(),
        favicons: FaviconStore = FaviconStore(),
        searchEngines: SearchEngineStore? = nil,
        downloads: DownloadManager? = nil,
        files: FileStore? = nil,
        playlists: PlaylistStore? = nil
    ) {
        self.preferences = preferences
        self.privateSession = privateSession
        self.tabStore = tabStore
        self.history = history
        self.bookmarks = bookmarks
        self.siteSettings = siteSettings
        self.favicons = favicons
        self.searchEngines = searchEngines ?? SearchEngineStore(preferences: preferences)
        self.downloads = downloads ?? DownloadManager(preferences: preferences)
        self.files = files ?? FileStore(preferences: preferences)
        self.playlists = playlists ?? PlaylistStore()
    }
}
