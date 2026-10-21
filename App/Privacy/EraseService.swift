import Foundation
import WebKit

/// What Clear Browsing Data removes.
struct ClearDataRequest {
    enum Range: String, CaseIterable, Identifiable {
        case lastHour = "The Last Hour"
        case today = "Today"
        case todayAndYesterday = "Today and Yesterday"
        case allTime = "All Time"

        var id: String { rawValue }

        /// The earliest change to remove, or nil for everything.
        var start: Date? {
            let calendar = Calendar.current
            switch self {
            case .lastHour: return Date().addingTimeInterval(-3600)
            case .today: return calendar.startOfDay(for: Date())
            case .todayAndYesterday: return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
            case .allTime: return nil
            }
        }
    }

    var range: Range = .allTime
    var history = true
    var cookiesAndSiteData = true
    var cache = true
    var closedTabs = true
}

/// Erasing private browsing (Firefox Focus's trash button) and clearing normal browsing data.
enum EraseService {
    /// Closes every private tab in every window and throws away the private data store, so all
    /// private cookies, storage and cache are gone.
    static func erasePrivateBrowsing(services: AppServices) {
        for window in services.tabStore.windowModels where window.isPrivate || !window.privateGroup.tabs.isEmpty {
            window.closeAllTabs(isPrivate: true)
        }
        services.privateSession.reset()
        URLCache.shared.removeAllCachedResponses()
        services.favicons.clearMemoryCache()
        Log.event("Erased private browsing", category: "privacy")
    }

    /// Clears data from normal browsing.
    static func clear(_ request: ClearDataRequest, services: AppServices) async {
        let began = Date()
        let start = request.range.start
        if request.history {
            services.history.clear(since: start)
        }
        var types = Set<String>()
        if request.cookiesAndSiteData {
            types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes))
        }
        if request.cache {
            types.formUnion(cacheTypes)
            if let start {
                URLCache.shared.removeCachedResponses(since: start)
            } else {
                URLCache.shared.removeAllCachedResponses()
            }
        }
        if !types.isEmpty {
            await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: start ?? .distantPast)
        }
        if request.closedTabs {
            services.tabStore.windowModels.forEach { $0.clearRecentlyClosed() }
        }
        if request.history && start == nil {
            services.favicons.removeAll()
        }
        let seconds = Date().timeIntervalSince(began).formatted(.number.precision(.fractionLength(1)))
        Log.event("Cleared browsing data (\(request.range.rawValue)) in \(seconds) s", category: "privacy")
    }

    private static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]
}
