import Foundation

/// App-wide state shared by every window.
final class AppServices {
    static let shared = AppServices()

    let preferences: Preferences
    let privateSession: PrivateSession
    let tabStore: TabStore

    init(
        preferences: Preferences = Preferences(),
        privateSession: PrivateSession = PrivateSession(),
        tabStore: TabStore = TabStore()
    ) {
        self.preferences = preferences
        self.privateSession = privateSession
        self.tabStore = tabStore
    }
}
