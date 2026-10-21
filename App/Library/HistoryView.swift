import BrowserCore
import SwiftUI

/// History of normal tabs, grouped by day and searchable.
struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var favicons: FaviconStore
    var onOpen: (URL) -> Void

    @State private var searchText = ""
    @State private var confirmingClear = false

    init(history: HistoryStore, favicons: FaviconStore, onOpen: @escaping (URL) -> Void) {
        self.history = history
        self.favicons = favicons
        self.onOpen = onOpen
    }

    var body: some View {
        let groups = history.index.groupedByDay(searchText)
        List {
            if groups.isEmpty {
                Text(searchText.isEmpty ? "Pages you visit in normal tabs appear here." : "No matches")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section(Self.dayTitle(group.day)) {
                    ForEach(group.entries) { entry in
                        Button {
                            onOpen(entry.url)
                        } label: {
                            HStack(spacing: 12) {
                                SiteIcon(url: entry.url, title: entry.title, favicons: favicons, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
                                    Text(URLDisplay.host(for: entry.url) ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { history.remove(entry.url) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search History")
        .navigationTitle("History")
        .toolbar {
            Button("Clear…") { confirmingClear = true }
                .disabled(history.index.entries.isEmpty)
        }
        .confirmationDialog("Clear History", isPresented: $confirmingClear) {
            Button("The Last Hour", role: .destructive) { history.clear(since: Date().addingTimeInterval(-3600)) }
            Button("Today", role: .destructive) { history.clear(since: Calendar.current.startOfDay(for: Date())) }
            Button("Today and Yesterday", role: .destructive) {
                let today = Calendar.current.startOfDay(for: Date())
                history.clear(since: Calendar.current.date(byAdding: .day, value: -1, to: today))
            }
            Button("All History", role: .destructive) { history.clear(since: nil) }
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// Saved bookmarks.
struct BookmarksView: View {
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var favicons: FaviconStore
    var onOpen: (URL) -> Void

    @State private var renaming: Bookmark?
    @State private var newName = ""

    init(bookmarks: BookmarkStore, favicons: FaviconStore, onOpen: @escaping (URL) -> Void) {
        self.bookmarks = bookmarks
        self.favicons = favicons
        self.onOpen = onOpen
    }

    var body: some View {
        List {
            if bookmarks.bookmarks.isEmpty {
                Text("Bookmark pages with Add Bookmark in the page menu or ⌘D.")
                    .foregroundStyle(.secondary)
            }
            ForEach(bookmarks.bookmarks) { bookmark in
                Button {
                    onOpen(bookmark.url)
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(url: bookmark.url, title: bookmark.title, favicons: favicons, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.title).lineLimit(1)
                            Text(URLDisplay.host(for: bookmark.url) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        newName = bookmark.title
                        renaming = bookmark
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button { UIPasteboard.general.url = bookmark.url } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { bookmarks.removeBookmark(id: bookmark.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { bookmarks.removeBookmark(id: bookmark.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Bookmarks")
        .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let bookmark = renaming {
                    bookmarks.renameBookmark(id: bookmark.id, to: newName)
                }
                renaming = nil
            }
        }
    }
}
