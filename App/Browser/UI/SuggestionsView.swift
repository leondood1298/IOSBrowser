import BrowserCore
import Combine
import SwiftUI

/// Suggestions shown under the address bar while typing: search suggestions (opt-in), open
/// tabs, bookmarks, history and "Find on Page".
final class SuggestionsModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [Suggestion] = []
    @Published private(set) var searchSuggestions: [String] = []
    @Published private(set) var canPaste = false
    /// Called when suggestions arrive later (from the network), so the panel can show itself.
    var onChange: (() -> Void)?

    private let services: AppServices
    private let window: BrowserWindowModel
    private var fetchTask: Task<Void, Never>?

    init(services: AppServices, window: BrowserWindowModel) {
        self.services = services
        self.window = window
    }

    /// Firefox Focus asks once before sending what you type to the search engine.
    var showsPrompt: Bool {
        !query.isEmpty && !services.preferences.searchSuggestionsPrompted
    }

    var showsFindRow: Bool {
        guard !query.isEmpty, let tab = window.selectedTab else { return false }
        return !tab.showsStartPage && tab.webView != nil
    }

    var hasContent: Bool {
        !results.isEmpty || !searchSuggestions.isEmpty || canPaste || showsPrompt || showsFindRow
    }

    func update(query: String) {
        self.query = query
        canPaste = query.isEmpty && (UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings)
        var candidates: [SuggestionRanker.Candidate] = []
        let isPrivate = window.isPrivate
        for tab in (isPrivate ? window.privateTabs : window.normalTabs) where tab !== window.selectedTab {
            if let url = tab.url {
                candidates.append(.init(kind: .openTab(id: tab.id), title: tab.title, url: url, lastUsed: tab.lastActive))
            }
        }
        for bookmark in services.bookmarks.bookmarks {
            candidates.append(.init(kind: .bookmark, title: bookmark.title, url: bookmark.url, lastUsed: bookmark.created))
        }
        if !isPrivate {
            for entry in services.history.index.search(query, limit: 200) {
                candidates.append(.init(
                    kind: .history, title: entry.title, url: entry.url, lastUsed: entry.lastVisit, useCount: entry.visitCount))
            }
        }
        results = SuggestionRanker.rank(query, candidates: candidates, limit: 6)
        fetchSearchSuggestions(for: query)
    }

    func answerPrompt(enable: Bool) {
        services.preferences.searchSuggestionsEnabled = enable
        services.preferences.searchSuggestionsPrompted = true
        update(query: query)
    }

    /// Asks the search engine for suggestions after a short pause in typing (0.1 s, like Focus).
    private func fetchSearchSuggestions(for query: String) {
        fetchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard services.preferences.searchSuggestionsEnabled, !trimmed.isEmpty,
              let url = services.searchEngines.defaultEngine.suggestURL(for: trimmed)
        else {
            searchSuggestions = []
            return
        }
        fetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let suggestions = await Self.fetch(url)
            guard !Task.isCancelled, let self, self.query == query else { return }
            self.searchSuggestions = suggestions
            self.onChange?()
        }
    }

    /// Fetches without cookies, so suggestions can't be tied to a signed-in account.
    nonisolated private static func fetch(_ url: URL) async -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let result = try? await session.data(from: url) else { return [] }
        return SuggestParser.parse(result.0)
    }
}

struct SuggestionsView: View {
    @ObservedObject var model: SuggestionsModel
    @ObservedObject var favicons: FaviconStore
    @ObservedObject var preferences: Preferences
    var onSelect: (Suggestion) -> Void
    var onSearch: (String) -> Void
    var onFindInPage: (String) -> Void
    var onPasteAndGo: () -> Void

    var body: some View {
        List {
            if model.showsPrompt {
                promptRow
            }
            if model.canPaste {
                Button(action: onPasteAndGo) {
                    Label("Paste and Go", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("pasteAndGo")
            }
            ForEach(model.searchSuggestions, id: \.self) { suggestion in
                Button {
                    onSearch(suggestion)
                } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("searchSuggestion")
            }
            ForEach(model.results) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(url: suggestion.url, title: suggestion.title, favicons: favicons, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title.isEmpty ? suggestion.url.absoluteString : suggestion.title)
                                .lineLimit(1)
                            Text(URLDisplay.editableText(for: suggestion.url) ?? suggestion.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        badge(for: suggestion.kind)
                    }
                    // The whole row responds, not just the text and icons.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("suggestionRow")
            }
            if model.showsFindRow {
                Button {
                    onFindInPage(model.query)
                } label: {
                    Label("Find “\(model.query)” on Page", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("findOnPageSuggestion")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("suggestions")
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Show Search Suggestions?").font(.headline)
            Text("To get suggestions, what you type in the address bar is sent to your search engine.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("No") { model.answerPrompt(enable: false) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("suggestionsPromptNo")
                Button("Yes") { model.answerPrompt(enable: true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("suggestionsPromptYes")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func badge(for kind: Suggestion.Kind) -> some View {
        switch kind {
        case .openTab:
            Label("Switch to Tab", systemImage: "arrow.right.square")
                .font(.caption)
                .foregroundStyle(.tint)
        case .bookmark:
            Image(systemName: "book").foregroundStyle(.secondary)
        case .history:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }
}
