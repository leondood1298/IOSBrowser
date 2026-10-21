import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Actions the New Tab page needs from the browser.
struct StartPageActions {
    var open: (URL) -> Void
}

/// The New Tab page: shortcuts (Firefox Focus's pinned sites), recently visited pages in
/// normal tabs, and an explanation in private tabs.
struct StartPageView: View {
    let isPrivate: Bool
    let actions: StartPageActions
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var favicons: FaviconStore

    @State private var renaming: Shortcut?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 20)]

    init(isPrivate: Bool, actions: StartPageActions, bookmarks: BookmarkStore, history: HistoryStore, favicons: FaviconStore) {
        self.isPrivate = isPrivate
        self.actions = actions
        self.bookmarks = bookmarks
        self.history = history
        self.favicons = favicons
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if isPrivate {
                    privateHeader
                }
                if !bookmarks.shortcuts.isEmpty {
                    section("Shortcuts") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(bookmarks.shortcuts) { shortcut in
                                tile(for: shortcut)
                            }
                        }
                    }
                } else if !isPrivate {
                    Text("Add sites you visit often with Add to Shortcuts in the page menu.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !isPrivate {
                    let recent = history.index.search(limit: 8)
                    if !recent.isEmpty {
                        section("Recently Visited") {
                            VStack(spacing: 0) {
                                ForEach(recent) { entry in
                                    recentRow(entry)
                                    if entry.id != recent.last?.id {
                                        Divider().padding(.leading, 52)
                                    }
                                }
                            }
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newTabPage")
        .alert("Rename Shortcut", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let shortcut = renaming {
                    bookmarks.renameShortcut(id: shortcut.id, to: newName)
                }
                renaming = nil
            }
        }
    }

    private var privateHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 34))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 6) {
                Text("Private Browsing").font(.title2.weight(.semibold))
                Text("Private tabs don't save history. Cookies and site data stay in memory and are erased when you tap Erase or quit the app.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }

    private func tile(for shortcut: Shortcut) -> some View {
        Button {
            actions.open(shortcut.url)
        } label: {
            VStack(spacing: 8) {
                SiteIcon(url: shortcut.url, title: shortcut.title, favicons: favicons, size: 64)
                Text(shortcut.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shortcut-\(shortcut.title)")
        .contextMenu {
            Button { actions.open(shortcut.url) } label: { Label("Open", systemImage: "arrow.up.right.square") }
            Button {
                newName = shortcut.title
                renaming = shortcut
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { bookmarks.removeShortcut(id: shortcut.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .draggable(shortcut.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            bookmarks.moveShortcut(id: id, to: shortcut.id)
            return true
        }
    }

    private func recentRow(_ entry: HistoryEntry) -> some View {
        Button {
            actions.open(entry.url)
        } label: {
            HStack(spacing: 12) {
                SiteIcon(url: entry.url, title: entry.title, favicons: favicons, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
                    Text(URLDisplay.host(for: entry.url) ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A site's favicon, or its first letter on a tinted square.
struct SiteIcon: View {
    let url: URL
    let title: String
    @ObservedObject var favicons: FaviconStore
    let size: CGFloat

    var body: some View {
        let corner = size * 0.22
        Group {
            if let icon = favicons.icon(for: url) {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Text(letter)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.gradient)
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.quaternary))
        .id(favicons.revision)
    }

    private var letter: String {
        let source = URLDisplay.host(for: url) ?? title
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}
