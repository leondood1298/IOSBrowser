import BrowserCore
import Combine
import SwiftUI

/// Suggestions shown under the address bar while typing: open tabs, bookmarks and history.
final class SuggestionsModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [Suggestion] = []
    @Published private(set) var canPaste = false

    private let services: AppServices
    private let window: BrowserWindowModel

    init(services: AppServices, window: BrowserWindowModel) {
        self.services = services
        self.window = window
    }

    func update(query: String) {
        self.query = query
        canPaste = UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings
        var candidates: [SuggestionRanker.Candidate] = []
        let isPrivate = window.isPrivate
        for tab in (isPrivate ? window.privateGroup.tabs : window.normalGroup.tabs) where tab !== window.selectedTab {
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
        results = SuggestionRanker.rank(query, candidates: candidates)
    }
}

struct SuggestionsView: View {
    @ObservedObject var model: SuggestionsModel
    @ObservedObject var favicons: FaviconStore
    var onSelect: (Suggestion) -> Void
    var onPasteAndGo: () -> Void

    var body: some View {
        List {
            if model.canPaste {
                Button(action: onPasteAndGo) {
                    Label("Paste and Go", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("pasteAndGo")
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
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("suggestions")
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
