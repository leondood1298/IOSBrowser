import BrowserCore
import CryptoKit
import WebKit

/// Compiles the bundled tracker block lists (once per list version) and applies the enabled ones
/// to every web view. Per-site exceptions are built into each list as a final
/// `ignore-previous-rules` rule, as Firefox does.
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// Lists that can be switched on: the four tracker categories and web fonts.
    enum List: Hashable {
        case trackers(TrackerCategory)
        case webFonts

        static let all: [List] = TrackerCategory.allCases.map { .trackers($0) } + [.webFonts]

        var resourceName: String {
            switch self {
            case .trackers(let category): return category.listName
            case .webFonts: return "web-fonts"
            }
        }
    }

    private(set) var isReady = false
    private(set) var matcher: TrackerMatcher?
    private var compiled: [List: WKContentRuleList] = [:]
    private var waiters: [() -> Void] = []
    private var compiledExceptions: [String]?
    private var services: AppServices { .shared }

    /// Compiles (or looks up) every list and builds the tracker matcher.
    func start() {
        guard compiledExceptions == nil else { return }
        compile()
        Task {
            matcher = await Self.makeMatcher()
        }
    }

    /// Runs `action` once the lists are compiled (right away if they already are).
    func whenReady(_ action: @escaping () -> Void) {
        if isReady {
            action()
        } else {
            waiters.append(action)
        }
    }

    /// Replaces the web view's rule lists with the ones that are switched on.
    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        for list in enabledLists() {
            if let ruleList = compiled[list] {
                controller.add(ruleList)
            }
        }
    }

    /// Call after a tracking protection setting or site exception changes: recompiles if the
    /// exceptions changed, then re-applies the lists to every open web view and reloads them.
    func settingsChanged() {
        if exceptionDomains() != compiledExceptions {
            compile()
        }
        whenReady { [weak self] in
            guard let self else { return }
            for window in self.services.tabStore.windowModels {
                for tab in window.allTabs {
                    guard let webView = tab.webView else { continue }
                    self.apply(to: webView.configuration.userContentController)
                    if webView.url != nil {
                        webView.reload()
                    }
                }
            }
        }
    }

    /// Which lists the current settings switch on.
    func enabledLists() -> [List] {
        let preferences = services.preferences
        var lists: [List] = []
        if preferences.trackingProtectionEnabled {
            lists += TrackerCategory.allCases.filter { preferences.isBlocking($0) }.map { .trackers($0) }
        }
        if preferences.blockWebFonts {
            lists.append(.webFonts)
        }
        return lists
    }

    /// Whether requests in `category` are blocked on `page` right now.
    func isBlocking(_ category: TrackerCategory, on page: URL?) -> Bool {
        let preferences = services.preferences
        return preferences.trackingProtectionEnabled && preferences.isBlocking(category)
            && services.siteSettings.settings(for: page).trackingProtectionDisabled != true
    }

    // MARK: - Compiling

    private func exceptionDomains() -> [String] {
        services.siteSettings.index.sites.filter { $0.value.trackingProtectionDisabled == true }.map(\.key).sorted()
    }

    private func compile() {
        isReady = false
        let exceptions = exceptionDomains()
        compiledExceptions = exceptions
        Task {
            await compileLists(exceptions: exceptions)
        }
    }

    private func compileLists(exceptions: [String]) async {
        var results: [List: WKContentRuleList] = [:]
        var identifiers: Set<String> = []
        for list in List.all {
            guard let url = Bundle.main.url(forResource: list.resourceName, withExtension: "json"),
                  let source = try? String(contentsOf: url, encoding: .utf8)
            else {
                Log.event("Missing block list \(list.resourceName)", category: "privacy")
                continue
            }
            let json = SafelistRules.appending(exceptions: exceptions, to: source)
            let digest = SHA256.hash(data: Data(json.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let identifier = "\(list.resourceName)-\(digest)"
            identifiers.insert(identifier)
            if let ruleList = await Self.ruleList(identifier: identifier, json: json) {
                results[list] = ruleList
            }
        }
        // A newer compile with different exceptions started meanwhile; let it finish instead.
        guard compiledExceptions == exceptions else { return }
        compiled = results
        isReady = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0() }
        Self.removeStaleLists(keeping: identifiers)
        Log.event("Content blocker ready with \(results.count) lists", category: "privacy")
    }

    /// A compiled list from WebKit's store, compiling it the first time.
    private static func ruleList(identifier: String, json: String) async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        let existing: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { ruleList, _ in
                continuation.resume(returning: ruleList)
            }
        }
        if let existing {
            return existing
        }
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { ruleList, error in
                if let error {
                    LogFile.shared.append("[privacy] Compiling \(identifier) failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: ruleList)
            }
        }
    }

    private static func removeStaleLists(keeping identifiers: Set<String>) {
        guard let store = WKContentRuleListStore.default() else { return }
        store.getAvailableContentRuleListIdentifiers { available in
            for identifier in available ?? [] where !identifiers.contains(identifier) {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }

    /// Builds the tracker matcher off the main thread (the lists and suffix list are large).
    nonisolated private static func makeMatcher() async -> TrackerMatcher {
        var lists: [TrackerCategory: Data] = [:]
        for category in TrackerCategory.allCases {
            if let url = Bundle.main.url(forResource: category.listName, withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                lists[category] = data
            }
        }
        let suffixText = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return TrackerMatcher(lists: lists, publicSuffixList: PublicSuffixList(text: suffixText))
    }
}
