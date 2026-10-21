import Foundation

/// Caps how many tabs keep a live web view across all windows. When a tab becomes active and the
/// cap is exceeded, the least recently used tabs that aren't on screen drop their web views.
final class WebViewBudget {
    static let shared = WebViewBudget()

    var limit = 8
    private var tabs: [WeakTab] = []

    private struct WeakTab {
        weak var tab: TabModel?
    }

    /// Records that `tab` is on screen with a live web view, then trims other tabs.
    func didShow(_ tab: TabModel, visibleTabIDs: Set<UUID>) {
        tab.markActive()
        tabs.removeAll { $0.tab == nil || $0.tab === tab }
        tabs.append(WeakTab(tab: tab))

        let live = tabs.compactMap(\.tab).filter(\.hasLiveWebView)
        guard live.count > limit else { return }
        let candidates = live
            .filter { !visibleTabIDs.contains($0.id) && $0 !== tab }
            .sorted { $0.lastActive < $1.lastActive }
        for candidate in candidates.prefix(live.count - limit) {
            candidate.discardWebView()
        }
    }

    func forget(_ tab: TabModel) {
        tabs.removeAll { $0.tab == nil || $0.tab === tab }
    }
}
