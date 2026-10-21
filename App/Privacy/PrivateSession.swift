import WebKit

/// The website data store shared by every private tab in every window. Nothing in it is written
/// to disk; Erase (M2) swaps in a fresh store, which drops all private cookies and site data.
final class PrivateSession {
    private(set) var dataStore = WKWebsiteDataStore.nonPersistent()

    func reset() {
        dataStore = WKWebsiteDataStore.nonPersistent()
    }
}
