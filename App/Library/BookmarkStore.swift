import BrowserCore
import Combine
import Foundation

/// Bookmarks and New Tab page shortcuts.
final class BookmarkStore: ObservableObject {
    @Published private(set) var library: BookmarkLibrary

    private let file: JSONFileStore<BookmarkLibrary>

    init(file: JSONFileStore<BookmarkLibrary> = LibraryFiles.store("bookmarks.json")) {
        self.file = file
        library = file.load() ?? BookmarkLibrary()
    }

    var bookmarks: [Bookmark] { library.bookmarks }
    var shortcuts: [Shortcut] { library.shortcuts }

    func isBookmarked(_ url: URL?) -> Bool {
        url.map(library.isBookmarked) ?? false
    }

    func hasShortcut(for url: URL?) -> Bool {
        url.map(library.hasShortcut) ?? false
    }

    // MARK: Bookmarks

    func addBookmark(title: String, url: URL) {
        guard !library.isBookmarked(url) else { return }
        library.bookmarks.insert(Bookmark(title: title.isEmpty ? url.absoluteString : title, url: url), at: 0)
        save()
    }

    func removeBookmark(for url: URL) {
        library.bookmarks.removeAll { BookmarkLibrary.same($0.url, url) }
        save()
    }

    func removeBookmark(id: UUID) {
        library.bookmarks.removeAll { $0.id == id }
        save()
    }

    func renameBookmark(id: UUID, to title: String) {
        guard let index = library.bookmarks.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        library.bookmarks[index].title = title
        save()
    }

    // MARK: Shortcuts

    func addShortcut(title: String, url: URL) {
        guard !library.hasShortcut(for: url) else { return }
        library.shortcuts.append(Shortcut(title: title.isEmpty ? (URLDisplay.host(for: url) ?? url.absoluteString) : title, url: url))
        save()
    }

    func removeShortcut(for url: URL) {
        library.shortcuts.removeAll { BookmarkLibrary.same($0.url, url) }
        save()
    }

    func removeShortcut(id: UUID) {
        library.shortcuts.removeAll { $0.id == id }
        save()
    }

    func renameShortcut(id: UUID, to title: String) {
        guard let index = library.shortcuts.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        library.shortcuts[index].title = title
        save()
    }

    /// Moves the shortcut `id` to where `target` is.
    func moveShortcut(id: UUID, to target: UUID) {
        guard let from = library.shortcuts.firstIndex(where: { $0.id == id }),
              let to = library.shortcuts.firstIndex(where: { $0.id == target }), from != to
        else { return }
        let shortcut = library.shortcuts.remove(at: from)
        library.shortcuts.insert(shortcut, at: to)
        save()
    }

    private func save() {
        LibraryFiles.write(library, to: file)
    }
}
